# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

"""pympv - Python wrapper for libmpv

libmpv is a client library for the media player mpv

For more info see: https://github.com/mpv-player/mpv/blob/master/libmpv/client.h
"""

import sys
import weakref
from threading import Thread, Lock
from libc.stdlib cimport malloc, free
from libc.string cimport strcpy

from client cimport *

__version__ = 0.2
__author__ = "Andre D"

_REQUIRED_CAPI_MAJOR = 1
_MIN_CAPI_MINOR = 9

cdef unsigned long _CAPI_VERSION
with nogil:
    _CAPI_VERSION = mpv_client_api_version()

_CAPI_MAJOR = _CAPI_VERSION >> 16
_CAPI_MINOR = _CAPI_VERSION & 0xFFFF

if _CAPI_MAJOR != _REQUIRED_CAPI_MAJOR or _CAPI_MINOR < _MIN_CAPI_MINOR:
    raise ImportError(
        "libmpv version is incorrect. Required %d.%d got %d.%d." %
            (_REQUIRED_CAPI_MAJOR, _MIN_CAPI_MINOR, _CAPI_MAJOR, _CAPI_MINOR)
    )

cdef extern from "Python.h":
    void PyEval_InitThreads()

_is_py3 = sys.version_info >= (3,)
_strdec_err = "surrogateescape" if _is_py3 else "strict"
# mpv -> Python
def _strdec(s):
    try:
        return s.decode("utf-8", _strdec_err)
    except UnicodeDecodeError:
        # In python2, bail to bytes on failure
        return bytes(s)

# Python -> mpv
def _strenc(s):
    try:
        return s.encode("utf-8", _strdec_err)
    except UnicodeEncodeError:
        # In python2, assume bytes and walk right through
        return s

PyEval_InitThreads()

class Errors:
    """Set of known error codes from MpvError and Event responses.

    Mostly wraps the enum mpv_error.
    Values might not always be integers in the future.
    You should handle the possibility that error codes may not be any of these values.
    """
    success = MPV_ERROR_SUCCESS
    queue_full = MPV_ERROR_EVENT_QUEUE_FULL
    nomem = MPV_ERROR_NOMEM
    uninitialized = MPV_ERROR_UNINITIALIZED
    invalid_parameter = MPV_ERROR_INVALID_PARAMETER
    not_found = MPV_ERROR_OPTION_NOT_FOUND
    option_format = MPV_ERROR_OPTION_FORMAT
    option_error = MPV_ERROR_OPTION_ERROR
    not_found = MPV_ERROR_PROPERTY_NOT_FOUND
    property_format = MPV_ERROR_PROPERTY_FORMAT
    property_unavailable = MPV_ERROR_PROPERTY_UNAVAILABLE
    property_error = MPV_ERROR_PROPERTY_ERROR
    command_error = MPV_ERROR_COMMAND
    loading_failed = MPV_ERROR_LOADING_FAILED
    ao_init_failed = MPV_ERROR_AO_INIT_FAILED
    vo_init_failed = MPV_ERROR_VO_INIT_FAILED
    nothing_to_play = MPV_ERROR_NOTHING_TO_PLAY
    unknown_format = MPV_ERROR_UNKNOWN_FORMAT


class Events:
    """Set of known values for Event ids.

    Mostly wraps the enum mpv_event_id.
    Values might not always be integers in the future.
    You should handle the possibility that event ids may not be any of these values.
    """
    none = MPV_EVENT_NONE
    shutdown = MPV_EVENT_SHUTDOWN
    log_message = MPV_EVENT_LOG_MESSAGE
    get_property_reply = MPV_EVENT_GET_PROPERTY_REPLY
    set_property_reply = MPV_EVENT_SET_PROPERTY_REPLY
    command_reply = MPV_EVENT_COMMAND_REPLY
    start_file = MPV_EVENT_START_FILE
    end_file = MPV_EVENT_END_FILE
    file_loaded = MPV_EVENT_FILE_LOADED
    tracks_changed = MPV_EVENT_TRACKS_CHANGED
    tracks_switched = MPV_EVENT_TRACK_SWITCHED
    idle = MPV_EVENT_IDLE
    pause = MPV_EVENT_PAUSE
    unpause = MPV_EVENT_UNPAUSE
    tick = MPV_EVENT_TICK
    script_input_dispatch = MPV_EVENT_SCRIPT_INPUT_DISPATCH
    client_message = MPV_EVENT_CLIENT_MESSAGE
    video_reconfig = MPV_EVENT_VIDEO_RECONFIG
    audio_reconfig = MPV_EVENT_AUDIO_RECONFIG
    metadata_update = MPV_EVENT_METADATA_UPDATE
    seek = MPV_EVENT_SEEK
    playback_restart = MPV_EVENT_PLAYBACK_RESTART
    property_change = MPV_EVENT_PROPERTY_CHANGE
    chapter_change = MPV_EVENT_CHAPTER_CHANGE


class LogLevels:
    no = MPV_LOG_LEVEL_NONE
    fatal = MPV_LOG_LEVEL_FATAL
    error = MPV_LOG_LEVEL_ERROR
    warn = MPV_LOG_LEVEL_WARN
    info = MPV_LOG_LEVEL_INFO
    v = MPV_LOG_LEVEL_V
    debug = MPV_LOG_LEVEL_DEBUG
    trace = MPV_LOG_LEVEL_TRACE


class EOFReasons:
    """Known possible values for EndOfFileReached reason.

    You should handle the possibility that the reason may not be any of these values.
    """
    eof = MPV_END_FILE_REASON_EOF
    aborted = MPV_END_FILE_REASON_STOP
    quit = MPV_END_FILE_REASON_QUIT
    error = MPV_END_FILE_REASON_ERROR


cdef class EndOfFileReached(object):
    """Data field for MPV_EVENT_END_FILE events

    Wraps: mpv_event_end_file
    """
    cdef public object reason, error

    cdef _init(self, mpv_event_end_file* eof):
        self.reason = eof.reason
        self.error = eof.error
        return self


cdef class InputDispatch(object):
    """Data field for MPV_EVENT_SCRIPT_INPUT_DISPATCH events.

    Wraps: mpv_event_script_input_dispatch
    """
    cdef public object arg0, type

    cdef _init(self, mpv_event_script_input_dispatch* input):
        self.arg0 = input.arg0
        self.type = _strdec(input.type)
        return self


cdef class LogMessage(object):
    """Data field for MPV_EVENT_LOG_MESSAGE events.

    Wraps: mpv_event_log_message
    """
    cdef public object prefix, level, text, log_level

    cdef _init(self, mpv_event_log_message* msg):
        self.level = _strdec(msg.level)
        self.prefix = _strdec(msg.prefix)
        self.text = _strdec(msg.text)
        self.log_level = msg.log_level
        return self


cdef _convert_node_value(mpv_node node):
    if node.format == MPV_FORMAT_STRING:
        return _strdec(node.u.string)
    elif node.format == MPV_FORMAT_FLAG:
        return not not int(node.u.flag)
    elif node.format == MPV_FORMAT_INT64:
        return int(node.u.int64)
    elif node.format == MPV_FORMAT_DOUBLE:
        return float(node.u.double_)
    elif node.format == MPV_FORMAT_NODE_MAP:
        return _convert_value(node.u.list, node.format)
    elif node.format == MPV_FORMAT_NODE_ARRAY:
        return _convert_value(node.u.list, node.format)
    return None


cdef _convert_value(void* data, mpv_format format):
    cdef mpv_node node
    cdef mpv_node_list nodelist
    if format == MPV_FORMAT_NODE:
        node = (<mpv_node*>data)[0]
        return _convert_node_value(node)
    elif format == MPV_FORMAT_NODE_ARRAY:
        nodelist = (<mpv_node_list*>data)[0]
        values = []
        for i in range(nodelist.num):
            values.append(_convert_node_value(nodelist.values[i]))
        return values
    elif format == MPV_FORMAT_NODE_MAP:
        nodelist = (<mpv_node_list*>data)[0]
        values = {}
        for i in range(nodelist.num):
            value = _convert_node_value(nodelist.values[i])
            values[_strdec(nodelist.keys[i])] = value
        return values
    elif format == MPV_FORMAT_STRING:
        return _strdec(((<char**>data)[0]))
    elif format == MPV_FORMAT_FLAG:
        return not not (<uint64_t*>data)[0]
    elif format == MPV_FORMAT_INT64:
        return int((<uint64_t*>data)[0])
    elif format == MPV_FORMAT_DOUBLE:
        return float((<double*>data)[0])
    return None


cdef class Property(object):
    """Data field for MPV_EVENT_PROPERTY_CHANGE and MPV_EVENT_GET_PROPERTY_REPLY.

    Wraps: mpv_event_property
    """
    cdef public object name, data

    cdef _init(self, mpv_event_property* prop):
        self.name = _strdec(prop.name)
        self.data = _convert_value(prop.data, prop.format)
        return self


cdef class Event(object):
    """Wraps: mpv_event"""
    cdef public mpv_event_id id
    cdef public int error
    cdef public object data, reply_userdata, observed_property

    @property
    def error_str(self):
        """mpv_error_string of the error proeprty"""
        cdef const char* err_c
        with nogil:
            err_c = mpv_error_string(self.error)
        return _strdec(err_c)

    cdef _data(self, mpv_event* event):
        cdef void* data = event.data
        cdef mpv_event_client_message* climsg
        if self.id == MPV_EVENT_GET_PROPERTY_REPLY:
            return Property()._init(<mpv_event_property*>data)
        elif self.id == MPV_EVENT_PROPERTY_CHANGE:
            return Property()._init(<mpv_event_property*>data)
        elif self.id == MPV_EVENT_LOG_MESSAGE:
            return LogMessage()._init(<mpv_event_log_message*>data)
        elif self.id == MPV_EVENT_SCRIPT_INPUT_DISPATCH:
            return InputDispatch()._init(<mpv_event_script_input_dispatch*>data)
        elif self.id == MPV_EVENT_CLIENT_MESSAGE:
            climsg = <mpv_event_client_message*>data
            args = []
            num_args = climsg.num_args
            for i in range(num_args):
                arg = <char*>climsg.args[i]
                arg = _strdec(arg)
                args.append(arg)
            return args
        elif self.id == MPV_EVENT_END_FILE:
            return EndOfFileReached()._init(<mpv_event_end_file*>data)
        return None

    @property
    def name(self):
        """mpv_event_name of the event id"""
        cdef const char* name_c
        with nogil:
            name_c = mpv_event_name(self.id)
        return _strdec(name_c)

    cdef _init(self, mpv_event* event, ctx):
        self.id = event.event_id
        self.data = self._data(event)
        if self.id == MPV_EVENT_PROPERTY_CHANGE:
            userdata = _async_data[id(ctx)].get(event.reply_userdata, None)
            self.observed_property = userdata
        else:
            userdata = _async_data[id(ctx)].pop(event.reply_userdata, None)
        self.reply_userdata = userdata.value() if userdata else None
        self.error = event.error
        return self


def _errors(fn):
    def wrapped(*k, **kw):
        v = fn(*k, **kw)
        if v < 0:
            raise MPVError(v)
    return wrapped


class MPVError(Exception):
    code = None

    def __init__(self, e):
        self.code = e
        cdef const char* err_c
        cdef int e_i = e
        if not isinstance(e, str):
            with nogil:
                err_c = mpv_error_string(e_i)
            e = _strdec(err_c)
        Exception.__init__(self, e)

cdef _callbacks = weakref.WeakValueDictionary()

class _AsyncDataSet(dict):
    pass

cdef _async_data = weakref.WeakValueDictionary()
class _AsyncData:
    def __init__(self, ctx, data):
        self._group = id(ctx)
        self._data = data
        _async_data[self._group][id(self)] = self

    def _remove(self):
        _async_data[self._group].pop(id(self))

    def value(self):
        return self._data


class ObservedProperty(_AsyncData):
    pass


cdef class Context(object):
    """Base class wrapping a context to interact with mpv.

    Assume all calls can raise MPVError.

    Wraps: mpv_create, mpv_destroy and all mpv_handle related calls
    """

    cdef mpv_handle *_ctx
    cdef object callback, callbackthread, async_data

    @property
    def name(self):
        """Unique name for every context created.

        Wraps: mpv_client_name
        """
        cdef const char* name
        with nogil:
            name = mpv_client_name(self._ctx)
        return _strdec(name)

    @property
    def time(self):
        """Internal mpv client time.

        Has an arbitrary start offset, but will never wrap or go backwards.

        Wraps: mpv_get_time_us
        """
        cdef int64_t time
        with nogil:
            time = mpv_get_time_us(self._ctx)
        return time

    def suspend(self):
        """Wraps: mpv_suspend"""
        with nogil:
            mpv_suspend(self._ctx)

    def resume(self):
        """Wraps: mpv_resume"""
        with nogil:
            mpv_resume(self._ctx)

    @_errors
    def request_event(self, event, enable):
        """Enable or disable a given event.

        Arguments:
        event - See Events
        enable - True to enable, False to disable

        Wraps: mpv_request_event
        """
        cdef int enable_i = 1 if enable else 0
        cdef int err
        cdef mpv_event_id event_id = event
        with nogil:
            err = mpv_request_event(self._ctx, event_id, enable_i)
        return err

    @_errors
    def set_log_level(self, loglevel):
        """Wraps: mpv_request_log_messages"""
        loglevel = _strenc(loglevel)
        cdef const char* loglevel_c = loglevel
        cdef int err
        with nogil:
            err = mpv_request_log_messages(self._ctx, loglevel_c)
        return err

    @_errors
    def load_config(self, filename):
        """Wraps: mpv_load_config_file"""
        filename = _strenc(filename)
        cdef const char* _filename = filename
        cdef int err
        with nogil:
            err = mpv_load_config_file(self._ctx, _filename)
        return err

    def _format_for(self, value):
        if isinstance(value, str):
            return MPV_FORMAT_STRING
        elif isinstance(value, bool):
            return MPV_FORMAT_FLAG
        elif isinstance(value, int):
            return MPV_FORMAT_INT64
        elif isinstance(value, float):
            return MPV_FORMAT_DOUBLE
        elif isinstance(value, (tuple, list)):
            return MPV_FORMAT_NODE_ARRAY
        elif isinstance(value, dict):
            return MPV_FORMAT_NODE_MAP
        return MPV_FORMAT_NONE

    cdef mpv_node_list* _prep_node_list(self, values):
        cdef mpv_node node
        cdef mpv_format format
        cdef mpv_node_list* node_list = <mpv_node_list*>malloc(sizeof(mpv_node_list))
        node_list.num = len(values)
        node_list.values = NULL
        node_list.keys = NULL
        if node_list.num:
            node_list.values = <mpv_node*>malloc(node_list.num * sizeof(mpv_node))
        for i, value in enumerate(values):
            format = self._format_for(value)
            node = self._prep_native_value(value, format)
            node_list.values[i] = node
        return node_list

    cdef mpv_node_list* _prep_node_map(self, map):
        cdef char* ckey
        cdef mpv_node_list* list
        list = self._prep_node_list(map.values())
        keys = map.keys()
        if not len(keys):
            return list
        list.keys = <char**>malloc(list.num)
        for i, key in enumerate(keys):
            key = _strenc(key)
            ckey = key
            list.keys[i] = <char*>malloc(len(key))
            strcpy(list.keys[i], ckey)
        return list

    cdef mpv_node _prep_native_value(self, value, format):
        cdef mpv_node node
        node.format = format
        if format == MPV_FORMAT_STRING:
            value = _strenc(value)
            node.u.string = <char*>malloc(len(value) + 1)
            strcpy(node.u.string, value)
        elif format == MPV_FORMAT_FLAG:
            node.u.flag = 1 if value else 0
        elif format == MPV_FORMAT_INT64:
            node.u.int64 = value
        elif format == MPV_FORMAT_DOUBLE:
            node.u.double_ = value
        elif format == MPV_FORMAT_NODE_ARRAY:
            node.u.list = self._prep_node_list(value)
        elif format == MPV_FORMAT_NODE_MAP:
            node.u.list = self._prep_node_map(value)
        else:
            node.format = MPV_FORMAT_NONE
        return node

    cdef _free_native_value(self, mpv_node node):
        if node.format in (MPV_FORMAT_NODE_ARRAY, MPV_FORMAT_NODE_MAP):
            for i in range(node.u.list.num):
                self._free_native_value(node.u.list.values[i])
            free(node.u.list.values)
            if node.format == MPV_FORMAT_NODE_MAP:
                for i in range(node.u.list.num):
                    free(node.u.list.keys[i])
                free(node.u.list.keys)
            free(node.u.list)
        elif node.format == MPV_FORMAT_STRING:
            free(node.u.string)

    def command(self, *cmdlist, async=False, data=None):
        """Send a command to mpv.

        Non-async success returns the command's response data, otherwise None

        Arguments:
        Accepts parameters as args

        Keyword Arguments:
        async: True will return right away, status comes in as MPV_EVENT_COMMAND_REPLY
        data: Only valid if async, gets sent back as reply_userdata in the Event

        Wraps: mpv_command_node and mpv_command_node_async
        """
        cdef mpv_node node = self._prep_native_value(cmdlist, self._format_for(cmdlist))
        cdef mpv_node noderesult
        cdef int err
        cdef uint64_t data_id
        result = None
        try:
            data_id = id(data)
            if not async:
                with nogil:
                    err = mpv_command_node(self._ctx, &node, &noderesult)
                try:
                    result = _convert_node_value(noderesult) if err >= 0 else None
                finally:
                    with nogil:
                        mpv_free_node_contents(&noderesult)
            else:
                data = _AsyncData(self, data) if data is not None else None
                with nogil:
                    err = mpv_command_node_async(self._ctx, data_id, &node)
        finally:
            self._free_native_value(node)
        if err < 0:
            raise MPVError(err)
        return result

    @_errors
    def get_property_async(self, prop, data=None):
        """Gets the value of a property asynchronously.

        Arguments:
        prop: Property to get the value of.

        Keyword arguments:
        data: Value to be passed into the reply_userdata of the response event.
        Wraps: mpv_get_property_async"""
        prop = _strenc(prop)
        data = _AsyncData(self, data) if data is not None else None
        cdef uint64_t id_data = id(data)
        cdef const char* prop_c = prop
        with nogil:
            err = mpv_get_property_async(
                self._ctx,
                id_data,
                prop_c,
                MPV_FORMAT_NODE,
            )
        if err < 0 and data:
            data._remove()
        return err

    def try_get_property_async(self, prop, data=None, default=None):
        try:
            return self.get_property_async(prop, data=data)
        except MPVError:
            return default

    def try_get_property(self, prop, default=None):
        try:
            return self.get_property(prop)
        except MPVError:
            return default

    def get_property(self, prop):
        """Wraps: mpv_get_property"""
        cdef mpv_node result
        prop = _strenc(prop)
        cdef const char* prop_c = prop
        cdef int err
        with nogil:
            err = mpv_get_property(
                self._ctx,
                prop_c,
                MPV_FORMAT_NODE,
                &result,
            )
        if err < 0:
            raise MPVError(err)
        try:
            v = _convert_node_value(result)
        finally:
            with nogil:
                mpv_free_node_contents(&result)
        return v

    @_errors
    def set_property(self, prop, value=True, async=False, data=None):
        """Wraps: mpv_set_property and mpv_set_property_async"""
        prop = _strenc(prop)
        cdef mpv_format format = self._format_for(value)
        cdef mpv_node v = self._prep_native_value(value, format)
        cdef int err
        cdef int data_id
        cdef const char* prop_c
        try:
            prop_c = prop
            if not async:
                with nogil:
                    err = mpv_set_property(
                        self._ctx,
                        prop_c,
                        MPV_FORMAT_NODE,
                        &v
                    )
                return err
            data = _AsyncData(self, data) if data is not None else None
            data_id = id(data)
            with nogil:
                err = mpv_set_property_async(
                    self._ctx,
                    data_id,
                    prop_c,
                    MPV_FORMAT_NODE,
                    &v
                )
        finally:
            self._free_native_value(v)
        if err < 0 and data:
            data._remove()
        return err

    @_errors
    def set_option(self, prop, value=True):
        """Wraps: mpv_set_option"""
        prop = _strenc(prop)
        cdef mpv_format format = self._format_for(value)
        cdef mpv_node v = self._prep_native_value(value, format)
        cdef int err
        cdef const char* prop_c
        try:
            prop_c = prop
            with nogil:
                err = mpv_set_option(
                    self._ctx,
                    prop_c,
                    MPV_FORMAT_NODE,
                    &v
                )
        finally:
            self._free_native_value(v)
        return err

    @_errors
    def initialize(self):
        """Wraps: mpv_initialize"""
        cdef int err
        with nogil:
            err = mpv_initialize(self._ctx)
        return err

    def wait_event(self, timeout=None):
        """Wraps: mpv_wait_event"""
        cdef double timeout_d = timeout if timeout is not None else -1
        cdef mpv_event* event
        with nogil:
            event = mpv_wait_event(self._ctx, timeout_d)
        return Event()._init(event, self)

    def wakeup(self):
        """Wraps: mpv_wakeup"""
        with nogil:
            mpv_wakeup(self._ctx)

    def set_wakeup_callback(self, callback):
        """Wraps: mpv_set_wakeup_callback"""
        cdef int64_t name = id(self)
        self.callback = callback
        self.callbackthread.set(callback)
        with nogil:
            mpv_set_wakeup_callback(self._ctx, _c_callback, <void*>name)

    def get_wakeup_pipe(self):
        """Wraps: mpv_get_wakeup_pipe"""
        cdef int pipe
        with nogil:
            pipe = mpv_get_wakeup_pipe(self._ctx)
        return pipe

    def __cinit__(self):
        with nogil:
            self._ctx = mpv_create()
        if not self._ctx:
            raise MPVError("Context creation error")
        self.callbackthread = CallbackThread()
        _callbacks[id(self)] = self.callbackthread
        self.async_data = _AsyncDataSet()
        _async_data[id(self)] = self.async_data
        self.callbackthread.start()

    def observe_property(self, prop, data=None):
        """Wraps: mpv_observe_property"""
        new = False
        if data is not None and not isinstance(data, ObservedProperty):
            new = True
            data = ObservedProperty(self, data)
        prop = _strenc(prop)
        cdef char* propc = prop
        cdef int err
        cdef uint64_t id_data = id(data)
        with nogil:
            err = mpv_observe_property(
                self._ctx,
                id_data,
                propc,
                MPV_FORMAT_NODE,
            )
        if err < 0:
            data._remove() if new else None
            raise MPVError(err)
        return data

    @_errors
    def unobserve_property(self, data):
        """Wraps: mpv_unobserve_property"""
        data._remove() if data else None
        cdef uint64_t id_data = id(data)
        cdef int err
        with nogil:
            err = mpv_unobserve_property(
                self._ctx,
                id_data,
            )
        return err

    def __dealloc__(self):
        with nogil:
            mpv_terminate_destroy(self._ctx)
        self.callbackthread.shutdown()

class CallbackThread(Thread):
    def __init__(self):
        Thread.__init__(self)
        self.daemon = True
        self.lock = Lock()
        self.lock.acquire(True)
        self.callback = None
        self.isshutdown = False

    def shutdown(self):
        self.isshutdown = True
        self.callback = None
        self.lock.release()

    def call(self):
        self.lock.release()

    def set(self, callback):
        if callback:
            callback = weakref.ref(callback)
        self.callback = callback

    def run(self):
        while not self.isshutdown:
            self.lock.acquire(True)
            callback = self.callback() if self.callback else None
            self.mpv_callback(callback) if callback else None

    def mpv_callback(self, callback):
        try:
            callback()
        except Exception as e:
            sys.stderr.write("pympv error during callback: %s\n" % e)

cdef void _c_callback(void* d) with gil:
    name = <int64_t>d
    callback = _callbacks.get(name)
    callback.call()
