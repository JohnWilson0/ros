# Software License Agreement (BSD License)
#
# Copyright (c) 2008, Willow Garage, Inc.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
#  * Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#  * Redistributions in binary form must reproduce the above
#    copyright notice, this list of conditions and the following
#    disclaimer in the documentation and/or other materials provided
#    with the distribution.
#  * Neither the name of Willow Garage, Inc. nor the names of its
#    contributors may be used to endorse or promote products derived
#    from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
# FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
# COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
# ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#
# Revision $Id$

## Support for ROS messages, including network serialization routines

import time
import struct
import logging
import traceback

from roslib.message import DeserializationError, Message

from rospy.core import ROSException, Time
from rospy.names import TOPIC_ANYTYPE

logger = logging.getLogger('rospy.msg')

## \ingroup client-api
## Message class to use for subscribing to any topic regardless
## of type. Incoming messages are not deserialized. Instead, the raw
## serialized data can be accssed via the buff property.
class AnyMsg(Message):
    _md5sum = TOPIC_ANYTYPE
    _type = TOPIC_ANYTYPE
    _has_header = False
    __slots__ = ['_buff']
    def __init__(self, *args):
        if len(args) != 0:
            raise ROSException("AnyMsg does not accept arguments")
        self._buff = None
    def serialize(self, buff):
        raise ROSException("Cannot publish messages of anytype")
    def deserialize(self, str):
        self._buff = str
        return self
        
## Serialize the message to the buffer \a b
## @param b StringIO: buffer to write to. WARNING: buffer will be reset after call
## @param msg Msg: message to write
## @param seq int: current sequence number (for headers)
def serialize_message(b, seq, msg):
    start = b.tell()
    b.seek(start+4) #reserve 4-bytes for length

    #update Header objects in msg state 
    tocheck = [msg] + [getattr(msg, attr) for attr in msg.__slots__]
    auto_headers = []
    for val in tocheck:
        if getattr(val.__class__, "_has_header", False):
            header = val.header
            header.seq = seq
            # auto_timestamp is true if header.stamp is zero
            auto_timestamp = not header.stamp
            if auto_timestamp:
                header.stamp = Time.now()
                auto_headers.append(header)
            if header.frame_id is None:
                header.frame_id = "0"

    #serialize the message data
    msg.serialize(b)

    #re-zero time object if we wrote into it
    for h in auto_headers:
        h.stamp.set(0, 0)

    #write 4-byte packet length
    # -4 don't include size of length header
    end = b.tell()
    size = end - 4 - start
    b.seek(start)
    b.write(struct.pack('<I', size))
    b.seek(end)

## Read all messages off the buffer \a b
##     
## @param b: buffer to read data from
## @param msg_queue: queue to append deserialized data to
## @param data_class: message deserialization class
## @param queue_size: message queue size. all but the last \a
## queue_size messages are discarded if this parameter is specified.
## @param start int: starting position to read in \a b
## @param max_msgs int: maximum number of messages to deserialize or None
## @throws roslib.message.DeserializationError: if an error/exception occurs during deserialization
def deserialize_messages(b, msg_queue, data_class, queue_size=None, max_msgs=None, start=0):
    try:
        pos = start
        btell = b.tell()
        left = btell - pos

        # check to see if we even have a message
        if left < 4:
            return
        
        # read in each message from the buffer as a string. each
        # message is preceded by a 4-byte integer length. the
        # serialized messages are appended to buff.
        b.seek(pos)
        buffs = []
        # size of message
        size = -1
        while (size < 0 and left >= 4) or (size > -1 and left >= size):
            # - read in the packet length
            #   NOTE: size is not inclusive of itself.
            if size < 0 and left >= 4:
                (size,) = struct.unpack('<I', b.read(4))
                left -= 4
            # - deserialize the complete buffer
            if size > -1 and left >= size:
                buffs.append(b.read(size))
                pos += size + 4
                left = btell - pos
                size = -1
                if max_msgs and len(buffs) >= max_msgs:
                    break

        #Before we deserialize, prune our buffers baed on the
        #queue_size rules.
        if queue_size is not None:
            buffs = buffs[-queue_size:]

        # Deserialize the messages into msg_queue, then trim the
        # msg_queue as specified.
        for q in buffs:
            data = data_class()
            msg_queue.append(data.deserialize(q))
        if queue_size is not None:
            del msg_queue[:-queue_size]
        
        #update buffer b to its correct write position.
        if btell == pos:
            #common case: no leftover data, reset the buffer
            b.seek(start)
            b.truncate(start)
        else:
            if pos != start:
                #next packet is stuck in our buffer, copy it to the
                #beginning of our buffer to keep things simple
                b.seek(pos)
                leftovers = b.read(btell-pos)
                b.truncate(start + len(leftovers))
                b.seek(start)
                b.write(leftovers)
            else:
                b.seek(btell)
    except Exception, e:
        logger.error("cannot deserialize message: EXCEPTION %s", traceback.format_exc())
        raise DeserializationError("cannot deserialize: %s"%str(e))

