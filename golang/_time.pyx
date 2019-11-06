# cython: language_level=2
# Copyright (C) 2019  Nexedi SA and Contributors.
#                     Kirill Smelkov <kirr@nexedi.com>
#
# This program is free software: you can Use, Study, Modify and Redistribute
# it under the terms of the GNU General Public License version 3, or (at your
# option) any later version, as published by the Free Software Foundation.
#
# You can also Link and Combine this program with other software covered by
# the terms of any of the Free Software licenses or any of the Open Source
# Initiative approved licenses and Convey the resulting work. Corresponding
# source of such a combination shall include the source code for all other
# software used.
#
# This program is distributed WITHOUT ANY WARRANTY; without even the implied
# warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
#
# See COPYING file for full licensing terms.
# See https://www.nexedi.com/licensing for rationale and options.
"""_time.pyx implements time.pyx - see _time.pxd for package overview."""

from __future__ import print_function, absolute_import

from golang cimport pychan, select, default, panic, topyexc
from golang cimport sync
from libc.math cimport INFINITY
from cython cimport final

from golang import go as pygo, panic as pypanic


def pynow(): # -> t
    return now_pyexc()

def pysleep(double dt):
    with nogil:
        sleep_pyexc(dt)


# ---- timers ----
# FIXME timers are implemented very inefficiently - each timer currently consumes a goroutine.

# tick returns channel connected to dt ticker.
#
# Note: there is no way to stop created ticker.
# Note: for dt <= 0, contrary to Ticker, tick returns nil channel instead of panicking.
def pytick(double dt):  # -> chan time
    if dt <= 0:
        return pychan._nil('C.double')
    return PyTicker(dt).c

# after returns channel connected to dt timer.
#
# Note: with after there is no way to stop/garbage-collect created timer until it fires.
def pyafter(double dt): # -> chan time
    return PyTimer(dt).c

# after_func arranges to call f after dt time.
#
# The function will be called in its own goroutine.
# Returned timer can be used to cancel the call.
def pyafter_func(double dt, f):  # -> PyTimer
    return PyTimer(dt, f=f)


# Ticker arranges for time events to be sent to .c channel on dt-interval basis.
#
# If the receiver is slow, Ticker does not queue events and skips them.
# Ticking can be canceled via .stop() .
@final
cdef class PyTicker:
    cdef readonly pychan  c # chan[double]

    cdef double      _dt
    cdef sync.Mutex  _mu
    cdef bint        __stop

    def __init__(PyTicker self, double dt):
        if dt <= 0:
            pypanic("ticker: dt <= 0")
        self.c      = pychan(1, dtype='C.double') # 1-buffer -- same as in Go
        self._dt    = dt
        self.__stop = False
        nogilready = pychan(dtype='C.structZ')
        pygo(self.__tick, self, nogilready)
        nogilready.recv()

    # stop cancels the ticker.
    #
    # It is guaranteed that ticker channel is empty after stop completes.
    def stop(PyTicker self):
        _Ticker_stop_pyexc(self)
    cdef void _stop(PyTicker self) nogil:
        c = self.c.chan_double()

        self._mu.lock()
        self.__stop = True

        # drain what __tick could have been queued already
        while c.len() > 0:
            c.recv()
        self._mu.unlock()

    cdef void __tick(PyTicker self, pychan nogilready) except +topyexc:
        with nogil:
            nogilready.chan_structZ().close()
            self.___tick()
    cdef void ___tick(PyTicker self) nogil:
        c = self.c.chan_double()
        while 1:
            # XXX adjust for accumulated error δ?
            sleep(self._dt)

            self._mu.lock()
            if self.__stop:
                self._mu.unlock()
                return

            # send from under ._mu so that .stop can be sure there is no
            # ongoing send while it drains the channel.
            t = now()
            select([
                default,
                c.sends(&t),
            ])
            self._mu.unlock()


# Timer arranges for time event to be sent to .c channel after dt time.
#
# The timer can be stopped (.stop), or reinitialized to another time (.reset).
#
# If func f is provided - when the timer fires f is called in its own goroutine
# instead of event being sent to channel .c .
@final
cdef class PyTimer:
    cdef readonly pychan  c

    cdef object     _f
    cdef sync.Mutex _mu
    cdef double     _dt   # +inf - stopped, otherwise - armed
    cdef int        _ver  # current timer was armed by n'th reset

    def __init__(PyTimer self, double dt, f=None):
        self._f     = f
        self.c      = pychan(1, dtype='C.double') if f is None else \
                      pychan._nil('C.double')
        self._dt    = INFINITY
        self._ver   = 0
        self.reset(dt)

    # stop cancels the timer.
    #
    # It returns:
    #
    #   False: the timer was already expired or stopped,
    #   True:  the timer was armed and canceled by this stop call.
    #
    # Note: contrary to Go version, there is no need to drain timer channel
    # after stop call - it is guaranteed that after stop the channel is empty.
    #
    # Note: similarly to Go, if Timer is used with function - it is not
    # guaranteed that after stop the function is not running - in such case
    # the caller must explicitly synchronize with that function to complete.
    def stop(PyTimer self): # -> canceled
        return _Timer_stop_pyexc(self)
    cdef bint _stop(PyTimer self) nogil: # -> canceled
        cdef bint canceled
        c = self.c.chan_double()

        self._mu.lock()

        if self._dt == INFINITY:
            canceled = False
        else:
            self._dt  = INFINITY
            self._ver += 1
            canceled = True

        # drain what __fire could have been queued already
        while c.len() > 0:
            c.recv()

        self._mu.unlock()
        return canceled

    # reset rearms the timer.
    #
    # the timer must be either already stopped or expired.
    def reset(PyTimer self, double dt):
        _Timer_reset_pyexc(self, dt)
    cdef void _reset(PyTimer self, double dt) nogil:
        self._mu.lock()
        if self._dt != INFINITY:
            self._mu.unlock()
            panic("Timer.reset: the timer is armed; must be stopped or expired")
        self._dt  = dt
        self._ver += 1
        # FIXME uses gil.
        # TODO rework timers so that new timer does not spawn new goroutine.
        ok = False
        with gil:
            nogilready = pychan(dtype='C.structZ')
            pygo(self.__fire, self, dt, self._ver, nogilready)
            nogilready.recv()
            ok = True
        self._mu.unlock()
        if not ok:
            panic("timer: reset: failed")

    cdef void __fire(PyTimer self, double dt, int ver, pychan nogilready) except +topyexc:
        with nogil:
            nogilready.chan_structZ().close()
            self.___fire(dt, ver)
    cdef void ___fire(PyTimer self, double dt, int ver) nogil:
        c = self.c.chan_double()
        sleep(dt)
        self._mu.lock()
        if self._ver != ver:
            self._mu.unlock()
            return  # the timer was stopped/resetted - don't fire it
        self._dt = INFINITY

        # send under ._mu so that .stop can be sure that if it sees
        # ._dt = INFINITY, there is no ongoing .c send.
        if self._f is None:
            c.send(now())
            self._mu.unlock()
            return
        self._mu.unlock()

        # call ._f not from under ._mu not to deadlock e.g. if ._f wants to reset the timer.
        with gil:
            ok = _callpyf(self._f)
        if not ok:
            panic("timer: fire: failed")


# ---- misc ----
pysecond        = second
pynanosecond    = nanosecond
pymicrosecond   = microsecond
pymillisecond   = millisecond
pyminute        = minute
pyhour          = hour

cdef double now_pyexc()             nogil except +topyexc:
    return now()
cdef void sleep_pyexc(double dt)    nogil except +topyexc:
    sleep(dt)

cdef void _Ticker_stop_pyexc(PyTicker t)            nogil except +topyexc:
    t._stop()
cdef bint _Timer_stop_pyexc (PyTimer t)             nogil except +topyexc:
    return t._stop()
cdef void _Timer_reset_pyexc(PyTimer t, double dt)  nogil except +topyexc:
    t._reset(dt)


cdef bint _callpyf(object f):
    f()
    return True
