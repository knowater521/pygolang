# -*- coding: utf-8 -*-
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
"""Package sync mirrors and amends Go package sync.

 - `WorkGroup` allows to spawn group of goroutines working on a common task(*).
 - `Once` allows to execute an action only once.
 - `WaitGroup` allows to wait for a collection of tasks to finish.
 - `Sema`(*) and `Mutex` provide low-level synchronization.

See also https://golang.org/pkg/sync for Go sync package documentation.

(*) not provided in Go version.
"""

from __future__ import print_function, absolute_import

import sys
from golang import go, defer, func
from golang import context

import six

from golang._sync import \
    PySema      as Sema,        \
    PyMutex     as Mutex,       \
    PyOnce      as Once,        \
    PyWaitGroup as WaitGroup,   \
    PyWorkGroup as WorkGroup
