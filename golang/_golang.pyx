# -*- coding: utf-8 -*-
# cython: language_level=2
# distutils: language = c++
# distutils: depends = libgolang.h
#
# Copyright (C) 2018-2019  Nexedi SA and Contributors.
#                          Kirill Smelkov <kirr@nexedi.com>
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
"""_golang.pyx provides Python interface to libgolang.{h,cpp}.

See _golang.pxd for package overview.
"""

from __future__ import print_function, absolute_import

# init libgolang runtime early
_init_libgolang()

from cpython cimport Py_INCREF, Py_DECREF, PY_MAJOR_VERSION
from cython cimport final

import sys
import six
import threading, collections, random
from golang._pycompat import im_class

# ---- panic ----

@final
cdef class _PanicError(Exception):
    pass

# panic stops normal execution of current goroutine.
cpdef pypanic(arg):
    raise _PanicError(arg)

# topyexc converts C-level panic/exc to python panic/exc.
# (see usage in e.g. *_pyexc functions in "misc")
cdef void topyexc() except *:
    # TODO use libunwind/libbacktrace/libstacktrace/... to append C-level traceback
    #      from where it panicked till topyexc user.
    # TODO install C-level traceback dump as std::terminate handler.
    #
    # recover_ is declared `except +` - if it was another - not panic -
    # exception, it will be converted to py exc by cython automatically.
    arg = recover_()
    if arg != NULL:
        pyarg = <bytes>arg
        if PY_MAJOR_VERSION >= 3:
            pyarg = pyarg.decode("utf-8")
        pypanic(pyarg)

cdef extern from "golang/libgolang.h" nogil:
    const char *recover_ "golang::recover" () except +


# ---- go ----

# go spawns lightweight thread.
#
# go spawns:
#
# - lightweight thread (with    gevent integration), or
# - full OS thread     (without gevent integration).
#
# Use gpython to run Python with integrated gevent, or use gevent directly to do so.
def pygo(f, *argv, **kw):
    _ = _togo(); _.f = f; _.argv = argv; _.kw    = kw
    Py_INCREF(_)    # we transfer 1 ref to _goviac
    with nogil:
        _taskgo_pyexc(_goviac, <void*>_)

@final
cdef class _togo:
    cdef object f
    cdef tuple  argv
    cdef dict   kw

cdef extern from "Python.h" nogil:
    ctypedef struct PyGILState_STATE:
        pass
    PyGILState_STATE PyGILState_Ensure()
    void PyGILState_Release(PyGILState_STATE)

cdef void _goviac(void *arg) nogil:
    # create new py thread state and keep it alive while __goviac runs.
    #
    # Just `with gil` is not enough: for `with gil` if exceptions could be
    # raised inside, cython generates several GIL release/reacquire calls.
    # This way the thread state will be deleted on first release and _new_ one
    # - _another_ thread state - create on acquire. All that implicitly with
    # the effect of loosing things associated with thread state - e.g. current
    # exception.
    #
    # -> be explicit and manually keep py thread state alive ourselves.
    gstate = PyGILState_Ensure() # py thread state will stay alive until PyGILState_Release
    __goviac(arg)
    PyGILState_Release(gstate)

cdef void __goviac(void *arg) nogil:
    with gil:
        try:
            _ = <_togo>arg
            Py_DECREF(_)
            _.f(*_.argv, **_.kw)
        except:
            # ignore exceptions during python interpreter shutdown.
            # python clears sys and other modules at exit which can result in
            # arbitrary exceptions in still alive "daemon" threads that go
            # spawns. Similarly to threading.py(*) we just ignore them.
            #
            # if we don't - there could lots of output like e.g. "lost sys.stderr"
            # and/or "sys.excepthook is missing" etc.
            #
            # (*) github.com/python/cpython/tree/v2.7.16-121-g53639dd55a0/Lib/threading.py#L760-L778
            #     see also "Technical details" in stackoverflow.com/a/12807285/9456786.
            if sys is None:
                return

            raise   # XXX exception -> exit program with traceback (same as in go) ?


# ---- channels ----

# _RecvWaiting represents a receiver waiting on a chan.
class _RecvWaiting(object):
    # .group    _WaitGroup      group of waiters this receiver is part of
    # .chan     chan            channel receiver is waiting on
    #
    # on wakeup: sender|closer -> receiver:
    #   .rx_                    rx_ for recv
    def __init__(self, group, ch):
        self.group = group
        self.chan  = ch
        group.register(self)

    # wakeup notifies waiting receiver that recv_ completed.
    def wakeup(self, rx, ok):
        self.rx_ = (rx, ok)
        self.group.wakeup()


# _SendWaiting represents a sender waiting on a chan.
class _SendWaiting(object):
    # .group    _WaitGroup      group of waiters this sender is part of
    # .chan     chan            channel sender is waiting on
    # .obj                      object that was passed to send
    #
    # on wakeup: receiver|closer -> sender:
    #   .ok     bool            whether send succeeded (it will not on close)
    def __init__(self, group, ch, obj):
        self.group = group
        self.chan  = ch
        self.obj   = obj
        group.register(self)

    # wakeup notifies waiting sender that send completed.
    def wakeup(self, ok):
        self.ok = ok
        self.group.wakeup()


# _WaitGroup is a group of waiting senders and receivers.
#
# Only 1 waiter from the group can succeed waiting.
class _WaitGroup(object):
    # ._waitv   [] of _{Send|Recv}Waiting
    # ._sema    semaphore   used for wakeup
    #
    # ._mu      lock    NOTE ∀ chan order is always: chan._mu > ._mu
    #
    # on wakeup: sender|receiver -> group:
    #   .which  _{Send|Recv}Waiting     instance which succeeded waiting.
    def __init__(self):
        self._waitv = []
        self._sema  = threading.Lock()   # in python it is valid to release lock from another thread.
        self._sema.acquire()
        self._mu    = threading.Lock()
        self.which  = None

    def register(self, wait):
        self._waitv.append(wait)

    # try_to_win tries to win waiter after it was dequeued from a channel's {_send|_recv}q.
    #
    # -> ok: true if won, false - if not.
    def try_to_win(self, waiter):
        with self._mu:
            if self.which is not None:
                return False
            else:
                self.which = waiter
                return True

    # wait waits for winning case of group to complete.
    def wait(self):
        self._sema.acquire()

    # wakeup wakes up the group.
    #
    # prior to wakeup try_to_win must have been called.
    # in practice this means that waiters queued to chan.{_send|_recv}q must
    # be dequeued with _dequeWaiter.
    def wakeup(self):
        assert self.which is not None
        self._sema.release()

    # dequeAll removes all registered waiters from their wait queues.
    def dequeAll(self):
        for w in self._waitv:
            ch = w.chan
            if isinstance(w, _SendWaiting):
                queue = ch._sendq
            else:
                assert isinstance(w, _RecvWaiting)
                queue = ch._recvq

            with ch._mu:
                try:
                    queue.remove(w)
                except ValueError:
                    pass


# _dequeWaiter dequeues a send or recv waiter from a channel's _recvq or _sendq.
#
# the channel owning {_recv|_send}q must be locked.
def _dequeWaiter(queue):
    while len(queue) > 0:
        w = queue.popleft()
        # if this waiter can win its group - return it.
        # if not - someone else from its group already has won, and so we anyway have
        # to remove the waiter from the queue.
        if w.group.try_to_win(w):
            return w

    return None


# pychan is Python channel with Go semantic.
class pychan(object):
    # ._cap         channel capacity
    # ._mu          lock
    # ._dataq       deque *: data buffer
    # ._recvq       deque _RecvWaiting: blocked receivers
    # ._sendq       deque _SendWaiting: blocked senders
    # ._closed      bool

    def __init__(self, size=0):
        self._cap       = size
        self._mu        = threading.Lock()
        self._dataq     = collections.deque()
        self._recvq     = collections.deque()
        self._sendq     = collections.deque()
        self._closed    = False

    # send sends object to a receiver.
    #
    # .send(obj)
    def send(self, obj):
        if self is pynilchan:
            _blockforever()

        self._mu.acquire()
        if 1:
            ok = self._trysend(obj)
            if ok:
                return

            g  = _WaitGroup()
            me = _SendWaiting(g, self, obj)
            self._sendq.append(me)

        self._mu.release()

        g.wait()
        assert g.which is me
        if not me.ok:
            pypanic("send on closed channel")

    # recv_ is "comma-ok" version of recv.
    #
    # ok is true - if receive was delivered by a successful send.
    # ok is false - if receive is due to channel being closed and empty.
    #
    # .recv_() -> (rx, ok)
    def recv_(self):
        if self is pynilchan:
            _blockforever()

        self._mu.acquire()
        if 1:
            rx_, ok = self._tryrecv()
            if ok:
                return rx_

            g  = _WaitGroup()
            me = _RecvWaiting(g, self)
            self._recvq.append(me)

        self._mu.release()

        g.wait()
        assert g.which is me
        return me.rx_

    # recv receives from the channel.
    #
    # .recv() -> rx
    def recv(self):
        rx, _ = self.recv_()
        return rx

    # _trysend(obj) -> ok
    #
    # must be called with ._mu held.
    # if ok or panic - returns with ._mu released.
    # if !ok - returns with ._mu still being held.
    def _trysend(self, obj):
        if self._closed:
            self._mu.release()
            pypanic("send on closed channel")

        # synchronous channel
        if self._cap == 0:
            recv = _dequeWaiter(self._recvq)
            if recv is None:
                return False

            self._mu.release()
            recv.wakeup(obj, True)
            return True

        # buffered channel
        else:
            if len(self._dataq) >= self._cap:
                return False

            self._dataq.append(obj)
            recv = _dequeWaiter(self._recvq)
            if recv is not None:
                rx = self._dataq.popleft()
                self._mu.release()
                recv.wakeup(rx, True)
            else:
                self._mu.release()

            return True

    # _tryrecv() -> rx_=(rx, ok), ok
    #
    # must be called with ._mu held.
    # if ok or panic - returns with ._mu released.
    # if !ok - returns with ._mu still being held.
    def _tryrecv(self):
        # buffered
        if len(self._dataq) > 0:
            rx = self._dataq.popleft()

            # wakeup a blocked writer, if there is any
            send = _dequeWaiter(self._sendq)
            if send is not None:
                self._dataq.append(send.obj)
                self._mu.release()
                send.wakeup(True)
            else:
                self._mu.release()

            return (rx, True), True

        # closed
        if self._closed:
            self._mu.release()
            return (None, False), True

        # sync | empty: there is waiting writer
        send = _dequeWaiter(self._sendq)
        if send is None:
            return (None, False), False

        self._mu.release()
        rx = send.obj
        send.wakeup(True)
        return (rx, True), True


    # close closes sending side of the channel.
    def close(self):
        if self is pynilchan:
            pypanic("close of nil channel")

        recvv = []
        sendv = []

        with self._mu:
            if self._closed:
                pypanic("close of closed channel")
            self._closed = True

            # schedule: wake-up all readers
            while 1:
                recv = _dequeWaiter(self._recvq)
                if recv is None:
                    break
                recvv.append(recv)

            # schedule: wake-up all writers (they will panic)
            while 1:
                send = _dequeWaiter(self._sendq)
                if send is None:
                    break
                sendv.append(send)

        # perform scheduled wakeups outside of ._mu
        for recv in recvv:
            recv.wakeup(None, False)
        for send in sendv:
            send.wakeup(False)


    def __len__(self):
        return len(self._dataq)

    def __repr__(self):
        if self is pynilchan:
            return "nilchan"
        else:
            return super(pychan, self).__repr__()


# pynilchan is the nil py channel.
#
# On nil channel: send/recv block forever; close panics.
pynilchan = pychan(None)    # TODO -> <chan*>(NULL) after move to Cython


# pydefault represents default case for pyselect.
pydefault  = object()

# unbound pychan.{send,recv,recv_}
_pychan_send  = pychan.send
_pychan_recv  = pychan.recv
_pychan_recv_ = pychan.recv_
if six.PY2:
    # on py3 class.func gets the func; on py2 - unbound_method(func)
    _pychan_send  = _pychan_send.__func__
    _pychan_recv  = _pychan_recv.__func__
    _pychan_recv_ = _pychan_recv_.__func__

# pyselect executes one ready send or receive channel case.
#
# if no case is ready and default case was provided, select chooses default.
# if no case is ready and default was not provided, select blocks until one case becomes ready.
#
# returns: selected case number and receive info (None if send case was selected).
#
# example:
#
#   _, _rx = select(
#       ch1.recv,           # 0
#       ch2.recv_,          # 1
#       (ch2.send, obj2),   # 2
#       default,            # 3
#   )
#   if _ == 0:
#       # _rx is what was received from ch1
#       ...
#   if _ == 1:
#       # _rx is (rx, ok) of what was received from ch2
#       ...
#   if _ == 2:
#       # we know obj2 was sent to ch2
#       ...
#   if _ == 3:
#       # default case
#       ...
def pyselect(*casev):
    # select promise: if multiple cases are ready - one will be selected randomly
    ncasev = list(enumerate(casev))
    random.shuffle(ncasev)

    # first pass: poll all cases and bail out in the end if default was provided
    recvv = [] # [](n, ch, commaok)
    sendv = [] # [](n, ch, tx)
    ndefault = None
    for (n, case) in ncasev:
        # default: remember we have it
        if case is pydefault:
            if ndefault is not None:
                pypanic("pyselect: multiple default")
            ndefault = n

        # send
        elif isinstance(case, tuple):
            send, tx = case
            if im_class(send) is not pychan:
                pypanic("pyselect: send on non-chan: %r" % (im_class(send),))
            if send.__func__ is not _pychan_send:
                pypanic("pyselect: send expected: %r" % (send,))

            ch = send.__self__
            if ch is not pynilchan:   # nil chan is never ready
                ch._mu.acquire()
                if 1:
                    ok = ch._trysend(tx)
                    if ok:
                        return n, None
                ch._mu.release()

                sendv.append((n, ch, tx))

        # recv
        else:
            recv = case
            if im_class(recv) is not pychan:
                pypanic("pyselect: recv on non-chan: %r" % (im_class(recv),))
            if recv.__func__ is _pychan_recv:
                commaok = False
            elif recv.__func__ is _pychan_recv_:
                commaok = True
            else:
                pypanic("pyselect: recv expected: %r" % (recv,))

            ch = recv.__self__
            if ch is not pynilchan:   # nil chan is never ready
                ch._mu.acquire()
                if 1:
                    rx_, ok = ch._tryrecv()
                    if ok:
                        if not commaok:
                            rx, ok = rx_
                            rx_ = rx
                        return n, rx_
                ch._mu.release()

                recvv.append((n, ch, commaok))

    # execute default if we have it
    if ndefault is not None:
        return ndefault, None

    # select{} or with nil-channels only -> block forever
    if len(recvv) + len(sendv) == 0:
        _blockforever()

    # second pass: subscribe and wait on all rx/tx cases
    g = _WaitGroup()

    # selected returns what was selected in g.
    # the return signature is the one of select.
    def selected():
        g.wait()
        sel = g.which
        if isinstance(sel, _SendWaiting):
            if not sel.ok:
                pypanic("send on closed channel")
            return sel.sel_n, None

        if isinstance(sel, _RecvWaiting):
            rx_ = sel.rx_
            if not sel.sel_commaok:
                rx, ok = rx_
                rx_ = rx
            return sel.sel_n, rx_

        raise AssertionError("select: unreachable")

    try:
        for n, ch, tx in sendv:
            ch._mu.acquire()
            with g._mu:
                # a case that we previously queued already won
                if g.which is not None:
                    ch._mu.release()
                    return selected()

                ok = ch._trysend(tx)
                if ok:
                    # don't let already queued cases win
                    g.which = "tx prepoll won"  # !None

                    return n, None

                w = _SendWaiting(g, ch, tx)
                w.sel_n = n
                ch._sendq.append(w)
            ch._mu.release()

        for n, ch, commaok in recvv:
            ch._mu.acquire()
            with g._mu:
                # a case that we previously queued already won
                if g.which is not None:
                    ch._mu.release()
                    return selected()

                rx_, ok = ch._tryrecv()
                if ok:
                    # don't let already queued cases win
                    g.which = "rx prepoll won"  # !None

                    if not commaok:
                        rx, ok = rx_
                        rx_ = rx
                    return n, rx_

                w = _RecvWaiting(g, ch)
                w.sel_n = n
                w.sel_commaok = commaok
                ch._recvq.append(w)
            ch._mu.release()

        return selected()

    finally:
        # unsubscribe not-succeeded waiters
        g.dequeAll()


# _blockforever blocks current goroutine forever.
def _blockforever():
    # take a lock twice. It will forever block on the second lock attempt.
    # Under gevent, similarly to Go, this raises "LoopExit: This operation
    # would block forever", if there are no other greenlets scheduled to be run.
    dead = threading.Lock()
    dead.acquire()
    dead.acquire()

# ---- init libgolang runtime ---

cdef extern from "golang/libgolang.h" namespace "golang" nogil:
    struct _libgolang_runtime_ops
    void _libgolang_init(const _libgolang_runtime_ops*)
from cpython cimport PyCapsule_Import

cdef void _init_libgolang() except*:
    # detect whether we are running under gevent or OS threads mode
    # -> use golang.runtime._runtime_(gevent|thread) as libgolang runtime.
    threadmod = "thread"
    if PY_MAJOR_VERSION >= 3:
        threadmod = "_thread"
    t = __import__(threadmod)
    runtime = "thread"
    if "gevent" in t.start_new_thread.__module__:
        runtime = "gevent"
    runtimemod = "golang.runtime." + "_runtime_" + runtime

    # PyCapsule_Import("golang.X") does not work properly while we are in the
    # process of importing golang (it tries to access "X" attribute of half-created
    # golang module). -> preimport runtimemod via regular import first.
    __import__(runtimemod)
    runtimecaps = (runtimemod + ".libgolang_runtime_ops").encode("utf-8") # py3
    cdef const _libgolang_runtime_ops *runtime_ops = \
        <const _libgolang_runtime_ops*>PyCapsule_Import(runtimecaps, 0)
    if runtime_ops == NULL:
        pypanic("init: %s: libgolang_runtime_ops=NULL" % runtimemod)
    _libgolang_init(runtime_ops)



# ---- misc ----

cdef extern from "golang/libgolang.h" namespace "golang" nogil:
    void _taskgo(void (*f)(void *), void *arg)

cdef nogil:

    void _taskgo_pyexc(void (*f)(void *) nogil, void *arg)      except +topyexc:
        _taskgo(f, arg)