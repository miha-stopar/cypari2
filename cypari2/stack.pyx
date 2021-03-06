"""
Memory management for Gens on the PARI stack or the heap
********************************************************
"""

#*****************************************************************************
#       Copyright (C) 2016 Luca De Feo <luca.defeo@polytechnique.edu>
#       Copyright (C) 2018 Jeroen Demeyer <J.Demeyer@UGent.be>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#                  http://www.gnu.org/licenses/
#*****************************************************************************

from __future__ import absolute_import, division, print_function
cimport cython

from cpython.ref cimport PyObject, Py_XINCREF, Py_XDECREF

from cysignals.signals cimport sig_on, sig_off
from cysignals.memory cimport check_malloc, sig_free

from .gen cimport Gen, Gen_new
from .paridecl cimport (avma, pari_mainstack, gnil, gcopy,
                        is_universal_constant, is_on_stack,
                        isclone, gclone, gclone_refc)

from warnings import warn


cdef extern from *:
    int sig_on_count "cysigs.sig_on_count"


# Singleton object to denote the top of the PARI stack
cdef object top_of_stack = object()

# Pointer to the Gen on the bottom of the PARI stack. This is the first
# element of the Gen linked list. If the linked list is empty, this
# equals top_of_stack. This pointer is *not* refcounted, so it does not
# prevent the stackbottom object from being deallocated. In that case,
# we update stackbottom in Gen.__dealloc__
cdef PyObject* stackbottom = <PyObject*>top_of_stack


cdef void remove_from_pari_stack(Gen self):
    global avma, stackbottom
    if <PyObject*>self is not stackbottom:
        print("ERROR: removing wrong instance of Gen")
        print(f"Expected: {<object>stackbottom}")
        print(f"Actual:   {self}")
    if self.sp() != avma:
        if avma > self.sp():
            print("ERROR: inconsistent avma when removing Gen from PARI stack")
            print(f"Expected: 0x{self.sp():x}")
            print(f"Actual:   0x{avma:x}")
        else:
            warn(f"cypari2 leaked {self.sp() - avma} bytes on the PARI stack",
                 RuntimeWarning, stacklevel=2)
    stackbottom = n = self.next
    self.next = NULL
    reset_avma()
    Py_XDECREF(n)


cdef inline Gen Gen_stack_new(GEN x):
    """
    Allocate and initialize a new instance of ``Gen`` wrapping
    a GEN on the PARI stack.
    """
    # INCREF(stackbottom) must be done BEFORE calling Gen_new
    # since Gen_new may invoke gc.collect() which would mess up
    # the PARI stack.
    global stackbottom
    Py_XINCREF(stackbottom)
    z = Gen_new(x, <GEN>avma)
    z.next = stackbottom
    stackbottom = <PyObject*>z
    if z.next is not <PyObject*>top_of_stack:
        s0 = z.sp()
        s1 = (<Gen>z.next).sp()
        if s0 > s1:
            raise SystemError(f"objects on PARI stack in invalid order (first: 0x{s0:x}; next: 0x{s1:x})")
    return z


cdef void reset_avma():
    """
    Reset PARI stack pointer to remove unused stuff from the PARI stack.

    Note that the actual data remains on the stack. Therefore, it is
    safe to use as long as no further PARI functions are called.
    """
    # NOTE: this can be called with an exception set (the error handler
    # does that)!
    global avma
    if stackbottom is <PyObject*>top_of_stack:
        avma = pari_mainstack.top
    else:
        avma = (<Gen>stackbottom).sp()


cdef void clear_stack():
    """
    Call ``sig_off()`` and clean the PARI stack.
    """
    sig_off()
    reset_avma()


cdef int move_gens_to_heap(pari_sp lim) except -1:
    """
    Move some/all Gens from the PARI stack to the heap.

    If lim == -1, move everything. Otherwise, keep moving as long as
    avma <= lim.
    """
    while avma <= lim and stackbottom is not <PyObject*>top_of_stack:
        sig_on()
        current = <Gen>stackbottom
        h = gclone(current.g)
        sig_off()
        remove_from_pari_stack(current)
        current.g = current.address = h


cdef Gen new_gen(GEN x):
    """
    Create a new ``Gen`` from a ``GEN``. Except if `x` is ``gnil``, then
    return ``None`` instead.

    Also call ``sig_off``() and clear the PARI stack.
    """
    sig_off()
    if x is gnil:
        reset_avma()
        return None
    return new_gen_noclear(x)


cdef Gen new_gen_noclear(GEN x):
    """
    Create a new ``Gen`` from a ``GEN``.
    """
    if not is_on_stack(x):
        reset_avma()
        if is_universal_constant(x):
            return Gen_new(x, NULL)
        elif isclone(x):
            gclone_refc(x)
            return Gen_new(x, x)
        raise RuntimeError("new_gen() argument not on PARI stack, not on PARI heap and not a universal constant")

    z = Gen_stack_new(x)

    # If we used over half of the PARI stack, move all Gens to the heap
    if (pari_mainstack.top - avma) >= pari_mainstack.size // 2:
        if sig_on_count == 0:
            try:
                move_gens_to_heap(-1)
            except MemoryError:
                pass

    return z


cdef Gen clone_gen(GEN x):
    x = gclone(x)
    clear_stack()
    return Gen_new(x, x)


cdef Gen clone_gen_noclear(GEN x):
    x = gclone(x)
    return Gen_new(x, x)


@cython.no_gc
cdef class DetachGen:
    """
    Destroy a :class:`Gen` but keep the ``GEN`` which is inside it.

    The typical usage is as follows:

    1. Creates the ``DetachGen`` object from a :class`Gen`.

    2. Removes all other references to that :class:`Gen`.

    3. Call the ``detach`` method to retrieve the ``GEN`` (or a copy of
       it if the original was not on the stack).
    """
    def __init__(self, s):
        self.source = s

    cdef GEN detach(self) except NULL:
        src = <Gen_base?>self.source

        # Whatever happens, delete self.source
        self.source = None

        # Verify that we hold the only reference to src
        if (<PyObject*>src).ob_refcnt != 1:
            raise SystemError("cannot detach a Gen which is still referenced")

        # Delete src safely, keeping it available as GEN
        cdef GEN res = src.g
        if not (is_on_stack(res) or is_universal_constant(res)):
            # Make a copy to the PARI stack
            res = gcopy(res)

        # delete src but do not change avma
        global avma
        cdef pari_sp av = avma
        del src
        avma = av
        return res
