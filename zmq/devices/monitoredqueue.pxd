"""MonitoredQueue class declarations.

Authors
-------
* MinRK
* Brian Granger
"""

#
#    Copyright (c) 2010 Min Ragan-Kelley, Brian Granger
#
#    This file is part of pyzmq.
#
#    pyzmq is free software; you can redistribute it and/or modify it under
#    the terms of the Lesser GNU General Public License as published by
#    the Free Software Foundation; either version 3 of the License, or
#    (at your option) any later version.
#
#    pyzmq is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    Lesser GNU General Public License for more details.
#
#    You should have received a copy of the Lesser GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

#-----------------------------------------------------------------------------
# Imports
#-----------------------------------------------------------------------------

from libzmq cimport *

#-----------------------------------------------------------------------------
# MonitoredQueue C functions
#-----------------------------------------------------------------------------

cdef inline int _relay(void *insocket_, void *outsocket_, void *sidesocket_, 
                zmq_msg_t msg, zmq_msg_t side_msg, zmq_msg_t id_msg,
                bint swap_ids) nogil:
    cdef int SNDLABEL
    cdef int rc
    cdef int64_t flag_2
    cdef int flag_3
    cdef int flags
    cdef bint more
    cdef size_t flagsz
    cdef void * flag_ptr
    
    if ZMQ_VERSION_MAJOR < 3:
        flagsz = sizeof (int64_t)
        flag_ptr = &flag_2
        SNDLABEL = ZMQ_SNDMORE
    else:
        flagsz = sizeof (int)
        flag_ptr = &flag_3
        SNDLABEL = ZMQ_SNDLABEL
        if ZMQ_VERSION_MAJOR == 3:
            # in 3.x, ROUTER prefix is 2.x-style with SNDMORE, rather than
            # new-style with SNDLABEL
            rc = zmq_getsockopt (outsocket_, ZMQ_TYPE, flag_ptr, &flagsz)
            # This will never actually happen until LIBZMQ-249 is resolved:
            if flag_3 == ZMQ_ROUTER:
                SNDLABEL = ZMQ_SNDMORE
    
    if rc < 0:
        return rc
    if swap_ids:# both router, must send second identity first
        # recv two ids into msg, id_msg
        rc = zmq_recvmsg (insocket_, &msg, 0)
        if ZMQ_VERSION_MAJOR == 3:
            # temporary workaround for LIBZMQ-249
            rc = zmq_getsockopt (outsocket_, ZMQ_RCVLABEL, flag_ptr, &flagsz)
            if flag_3:
                SNDLABEL = ZMQ_SNDLABEL
            else:
                SNDLABEL = ZMQ_SNDMORE
        rc = zmq_recvmsg (insocket_, &id_msg, 0)

        # send second id (id_msg) first
        #!!!! always send a copy before the original !!!!
        rc = zmq_msg_copy(&side_msg, &id_msg)
        rc = zmq_sendmsg (outsocket_, &side_msg, SNDLABEL)
        rc = zmq_sendmsg (sidesocket_, &id_msg, ZMQ_SNDMORE)
        # send first id (msg) second
        rc = zmq_msg_copy(&side_msg, &msg)
        rc = zmq_sendmsg (outsocket_, &side_msg, SNDLABEL)
        rc = zmq_sendmsg (sidesocket_, &msg, ZMQ_SNDMORE)
        if rc < 0:
            return rc
    while (True):
        rc = zmq_recvmsg (insocket_, &msg, 0)
        # assert (rc == 0)
        rc = zmq_getsockopt (insocket_, ZMQ_RCVMORE, flag_ptr, &flagsz)
        flags = 0
        if ZMQ_VERSION_MAJOR < 3:
            if flag_2:
                flags |= ZMQ_SNDMORE
        else:
            if flag_3:
                flags |= ZMQ_SNDMORE
            rc = zmq_getsockopt (insocket_, ZMQ_RCVLABEL, flag_ptr, &flagsz)
            if flag_3:
                flags |= ZMQ_SNDLABEL
        # assert (rc == 0)

        rc = zmq_msg_copy(&side_msg, &msg)
        if flags:
            rc = zmq_sendmsg (outsocket_, &side_msg, flags)
            # only SNDMORE for side-socket
            rc = zmq_sendmsg (sidesocket_, &msg, ZMQ_SNDMORE)
        else:
            rc = zmq_sendmsg (outsocket_, &side_msg, 0)
            rc = zmq_sendmsg (sidesocket_, &msg, 0)
            break
    return rc

# the MonitoredQueue C function, adapted from zmq::queue.cpp :
cdef inline int c_monitored_queue (void *insocket_, void *outsocket_,
                        void *sidesocket_, zmq_msg_t *in_msg_ptr, 
                        zmq_msg_t *out_msg_ptr, int swap_ids) nogil:
    """The actual C function for a monitored queue device. 

    See ``monitored_queue()`` for details.
    """
    
    cdef zmq_msg_t msg
    cdef int rc = zmq_msg_init (&msg)
    cdef zmq_msg_t id_msg
    rc = zmq_msg_init (&id_msg)
    cdef zmq_msg_t side_msg
    rc = zmq_msg_init (&side_msg)
    # assert (rc == 0)
    
    
    cdef zmq_pollitem_t items [2]
    items [0].socket = insocket_
    items [0].fd = 0
    items [0].events = ZMQ_POLLIN
    items [0].revents = 0
    items [1].socket = outsocket_
    items [1].fd = 0
    items [1].events = ZMQ_POLLIN
    items [1].revents = 0
    # I don't think sidesocket should be polled?
    # items [2].socket = sidesocket_
    # items [2].fd = 0
    # items [2].events = ZMQ_POLLIN
    # items [2].revents = 0
    
    while (True):
    
        # //  Wait while there are either requests or replies to process.
        rc = zmq_poll (&items [0], 2, -1)
        if rc < 0:
            return rc
        # //  The algorithm below asumes ratio of request and replies processed
        # //  under full load to be 1:1. Although processing requests replies
        # //  first is tempting it is suspectible to DoS attacks (overloading
        # //  the system with unsolicited replies).
        # 
        # //  Process a request.
        if (items [0].revents & ZMQ_POLLIN):
            # send in_prefix to side socket
            rc = zmq_msg_copy(&side_msg, in_msg_ptr)
            rc = zmq_sendmsg (sidesocket_, &side_msg, ZMQ_SNDMORE)
            if rc < 0:
                return rc
            # relay the rest of the message
            rc = _relay(insocket_, outsocket_, sidesocket_, msg, side_msg, id_msg, swap_ids)
            if rc < 0:
                return rc
        if (items [1].revents & ZMQ_POLLIN):
            # send out_prefix to side socket
            rc = zmq_msg_copy(&side_msg, out_msg_ptr)
            rc = zmq_sendmsg (sidesocket_, &side_msg, ZMQ_SNDMORE)
            if rc < 0:
                return rc
            # relay the rest of the message
            rc = _relay(outsocket_, insocket_, sidesocket_, msg, side_msg, id_msg, swap_ids)
            if rc < 0:
                return rc
    return 0
