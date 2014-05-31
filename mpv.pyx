cimport cython
import sys
from libc.stdlib cimport malloc, free
from client cimport *

_MPV_C_CLIENT_API_VERSION = 0

if mpv_client_api_version() >> 16 != _MPV_C_CLIENT_API_VERSION:
    raise ImportError('libmpv version is incorrect') 

_is_py3 = sys.version_info >= (3,)
_strdec_err = 'surrogateescape' if _is_py3 else 'strict'
def _strdec(s):
    try:
        return s.decode('utf-8', _strdec_err)
    except UnicodeDecodeError:
        return bytes(s)

class Events:
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

class EOFReasons:
    eof = 0
    restarted = 1
    aborted = 2
    quit = 3

cdef class EndOfFileReached(object):
    cdef public object reason

    cdef _init(self, mpv_event_end_file* eof):
        self.reason = eof.reason
        return self

cdef class InputDispatch(object):
    cdef public object arg0, type

    cdef _init(self, mpv_event_script_input_dispatch* input):
        self.arg0 = input.arg0
        self.type = _strdec(input.type)
        return self

cdef class LogMessage(object):
    cdef public object prefix, level, text

    cdef _init(self, mpv_event_log_message* msg):
        self.level = _strdec(msg.level)
        self.prefix = _strdec(msg.level)
        self.text = _strdec(msg.level)
        return self

cdef _convert_value(void* data, mpv_format format):
    if format == MPV_FORMAT_STRING:
        return _strdec(((<char**>data)[0]))
    elif format == MPV_FORMAT_FLAG:
        return not not (<uint64_t*>data)[0]
    elif format == MPV_FORMAT_INT64:
        return int((<uint64_t*>data)[0])
    elif format == MPV_FORMAT_DOUBLE:
        return float((<double*>data)[0])
    return None

cdef class Property(object):
    cdef public object name, data
    
    cdef _init(self, mpv_event_property* prop):
        self.name = _strdec(prop.name)
        self.data = _convert_value(prop.data, prop.format)
        return self

cdef class Event(object):
    cdef public object id, data, reply_userdata, error

    @property
    def error_str(self):
        return _strdec(mpv_error_string(self.error))

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
            for i in range(0, num_args):
                arg = <char*>climsg.args[i]
                arg = _strdec(arg)
                args.append(arg)
            return args
        elif self.id == MPV_EVENT_END_FILE:
            return EndOfFileReached()._init(<mpv_event_end_file*>data)
        return None

    @property
    def name(self):
        return _strdec(mpv_event_name(self.id))

    cdef _init(self, mpv_event* event):
        self.id = event.event_id
        self.data = self._data(event)
        self.reply_userdata = event.reply_userdata
        self.error = event.error
        return self

def errors(infn):
    def fn(*k, **kw):
        v = infn(*k, **kw)
        if v < 0:
            raise MPVError(v)
    return fn

class MPVError(Exception):
    def __init__(self, e):
        if not isinstance(e, str):
            e = _strdec(mpv_error_string(e))
        Exception.__init__(self, e)

cdef class Context(object):
    cdef mpv_handle *_ctx

    @property
    def name(self):
        return _strdec(mpv_client_name(self._ctx))

    @property
    def time(self):
        return mpv_get_time_us(self._ctx)

    def suspend(self):
        mpv_suspend(self._ctx)

    def resume(self):
        mpv_resume(self._ctx)

    @errors
    def load_config(self, filename):
        filename = filename.encode('utf-8')
        cdef const char* _filename = filename
        return mpv_load_config_file(self._ctx, _filename)

    def _format_for(self, value):
        if isinstance(value, str):
            return MPV_FORMAT_STRING
        elif isinstance(value, bool):
            return MPV_FORMAT_FLAG
        elif isinstance(value, int):
            return MPV_FORMAT_INT64
        elif isinstance(value, float):
            return MPV_FORMAT_DOUBLE
        return MPV_FORMAT_NONE

    def _convert_value(self, value, format):
        if format == MPV_FORMAT_STRING:
            return value.encode('utf-8')
        if format == MPV_FORMAT_FLAG:
            value = 1 if value else 0
        return value

    @errors
    def command(self, *cmdlist):
        lsize = (len(cmdlist) + 1) * cython.sizeof(cython.pp_char)
        cdef const char** cmds = <const char**>malloc(lsize)
        if not cmds:
            raise MemoryError
        cmdlist = [cmd.encode('utf-8') for cmd in cmdlist]
        for i, cmd in enumerate(cmdlist):
            cmds[i] = <char*>cmd
        cmds[i + 1] = NULL
        rv = mpv_command(self._ctx, cmds)
        free(cmds)
        return rv

    def get_property(self, prop):
        cdef mpv_node result
        prop = prop.encode('utf-8')
        v = mpv_get_property(
            self._ctx,
            <const char*>prop,
            MPV_FORMAT_NODE,
            &result,
        )
        if v < 0:
            raise MPVError(v)
        if result.format == MPV_FORMAT_STRING:
            v = _strdec(result.u.string)
        elif result.format == MPV_FORMAT_FLAG:
            v = not not int(result.u.flag)
        elif result.format == MPV_FORMAT_INT64:
            v = int(result.u.int64)
        elif result.format == MPV_FORMAT_DOUBLE:
            v = float(result.u.double_)
        mpv_free_node_contents(&result)
        return v

    @errors
    def set_option(self, prop, value=True):
        cdef mpv_format format = self._format_for(value)
        value = self._convert_value(value, format)
        prop = prop.encode('utf-8')
        cdef void* v
        cdef char* cv
        cdef uint64_t iv
        if format == MPV_FORMAT_STRING:
            cv = <char*>value
            v = &cv
        elif format == MPV_FORMAT_NONE:
            v = NULL
        else:
            iv = value
            v = &iv
        return mpv_set_option(
            self._ctx,
            <const char*>prop,
            format,
            v
        )

    @errors
    def initialize(self):
        return mpv_initialize(self._ctx)

    def wait_event(self, timeout=None):
        timeout = timeout or 0
        return Event()._init(mpv_wait_event(self._ctx, timeout))

    def __cinit__(self):
        self._ctx = mpv_create()
        if not self._ctx:
            raise MPVError('Context creation error')

    def __dealloc__(self):
        mpv_destroy(self._ctx)
