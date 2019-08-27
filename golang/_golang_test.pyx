# -*- coding: utf-8 -*-
# cython: language_level=2
# distutils: language=c++
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

# small tests that verifies pyx-level channel API.
# the work of channels themselves is exercised thoroughly mostly in golang_test.py

from __future__ import print_function, absolute_import

from golang cimport go, panic, topyexc


# small test to verify pyx(nogil) go.
cdef void _test_go_nogil() nogil except +topyexc:
    go(_work, 111)
    # TODO wait till _work is done
cdef void _work(int i) nogil:
    if i != 111:
        panic("_work: i != 111")

def test_go_nogil():
    with nogil:
        _test_go_nogil()


# runtime/libgolang_test_c.c
cdef extern from * nogil:
    """
    extern "C" void _test_go_c();
    """
    void _test_go_c()   except +topyexc
def test_go_c():
    with nogil:
        _test_go_c()

# runtime/libgolang_test.cpp
cdef extern from * nogil:
    """
    extern void _test_go_cpp();
    """
    void _test_go_cpp()                         except +topyexc
def test_go_cpp():
    with nogil:
        _test_go_cpp()