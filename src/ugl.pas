{ ============================================================================
  ugl.pas  --  загрузчик точек входа OpenGL 3.3 Core Profile

  Вместо того чтобы линковаться с libGL и получать функции 1.1, мы объявляем
  указатели на функции и заполняем их через glfwGetProcAddress. Это рабочий
  способ для всех современных драйверов и всех трёх ОС.

  Берём только Core 3.3 (+ пара расширений для буферов), без старого
  фиксированного конвейера.
  ============================================================================ }
unit ugl;

{$MODE OBJFPC}
{$H+}
{$PACKRECORDS C}

interface

uses
  uglfw;

type
  GLenum     = Cardinal;
  GLboolean  = Byte;
  GLbitfield = Cardinal;
  GLint      = Integer;
  GLuint     = Cardinal;
  GLsizei    = Integer;
  GLfloat    = Single;
  GLdouble   = Double;
  GLchar     = Char;
  GLintptr   = PtrInt;
  GLsizeiptr = PtrInt;
  GLsync     = Pointer;
  GLuint64   = QWord;

  PGLuint  = ^GLuint;
  PGLint   = ^GLint;
  PGLfloat = ^GLfloat;
  PGLchar  = ^GLchar;

const
  GL_FALSE = 0;
  GL_TRUE  = 1;

  GL_POINTS         = $0000;
  GL_LINES          = $0001;
  GL_LINE_STRIP     = $0003;
  GL_TRIANGLES      = $0004;
  GL_TRIANGLE_STRIP = $0005;

  GL_DEPTH_BUFFER_BIT   = $00000100;
  GL_STENCIL_BUFFER_BIT = $00000400;
  GL_COLOR_BUFFER_BIT   = $00004000;

  { закадровый рендер }
  GL_FRAMEBUFFER          = $8D40;
  GL_RENDERBUFFER         = $8D41;
  GL_COLOR_ATTACHMENT0    = $8CE0;
  GL_DEPTH_ATTACHMENT     = $8D00;
  GL_FRAMEBUFFER_COMPLETE = $8CD5;
  GL_DEPTH_COMPONENT24    = $81A6;

  GL_NEVER    = $0200;
  GL_LESS     = $0201;
  GL_EQUAL    = $0202;
  GL_LEQUAL   = $0203;
  GL_GREATER  = $0204;
  GL_ALWAYS   = $0207;

  GL_SRC_ALPHA           = $0302;
  GL_ONE_MINUS_SRC_ALPHA = $0303;
  GL_ONE                 = 1;
  GL_ZERO                = 0;

  GL_FRONT          = $0404;
  GL_BACK           = $0405;
  GL_CULL_FACE      = $0B44;
  GL_DEPTH_TEST     = $0B71;
  GL_BLEND          = $0BE2;
  GL_MULTISAMPLE    = $809D;
  GL_FRAMEBUFFER_SRGB = $8DB9;
  GL_CW             = $0900;
  GL_CCW            = $0901;
  GL_DEPTH_WRITEMASK = $0B72;
  GL_LINE_SMOOTH    = $0B20;
  GL_POLYGON_OFFSET_FILL = $8037;

  GL_BYTE           = $1400;
  GL_UNSIGNED_BYTE  = $1401;
  GL_SHORT          = $1402;
  GL_UNSIGNED_SHORT = $1403;
  GL_INT            = $1404;
  GL_UNSIGNED_INT   = $1405;
  GL_FLOAT          = $1406;

  GL_VENDOR     = $1F00;
  GL_RENDERER   = $1F01;
  GL_VERSION    = $1F02;
  GL_EXTENSIONS = $1F03;
  GL_SHADING_LANGUAGE_VERSION = $8B8C;

  GL_ARRAY_BUFFER         = $8892;
  GL_ELEMENT_ARRAY_BUFFER = $8893;
  GL_UNIFORM_BUFFER       = $8A11;
  GL_STREAM_DRAW          = $88E0;
  GL_STATIC_DRAW          = $88E4;
  GL_DYNAMIC_DRAW         = $88E8;
  GL_MAP_WRITE_BIT        = $0002;
  GL_MAP_INVALIDATE_BUFFER_BIT = $0008;
  GL_MAP_UNSYNCHRONIZED_BIT    = $0020;

  GL_FRAGMENT_SHADER = $8B30;
  GL_VERTEX_SHADER   = $8B31;
  GL_COMPILE_STATUS  = $8B81;
  GL_LINK_STATUS     = $8B82;
  GL_INFO_LOG_LENGTH = $8B84;

  GL_TEXTURE_2D       = $0DE1;
  GL_TEXTURE0         = $84C0;
  GL_TEXTURE_MIN_FILTER = $2801;
  GL_TEXTURE_MAG_FILTER = $2800;
  GL_TEXTURE_WRAP_S     = $2802;
  GL_TEXTURE_WRAP_T     = $2803;
  GL_NEAREST            = $2600;
  GL_LINEAR             = $2601;
  GL_LINEAR_MIPMAP_LINEAR = $2703;
  GL_REPEAT             = $2901;
  GL_CLAMP_TO_EDGE      = $812F;
  GL_RGB                = $1907;
  GL_RGBA               = $1908;
  GL_RGBA8              = $8058;
  GL_SRGB8_ALPHA8       = $8C43;
  GL_TEXTURE_MAX_ANISOTROPY_EXT = $84FE;

  GL_NO_ERROR = 0;

var
  { ---- состояние и очистка ---- }
  glClear:        procedure(mask: GLbitfield); cdecl;
  glClearColor:   procedure(r, g, b, a: GLfloat); cdecl;
  glClearDepth:   procedure(d: GLdouble); cdecl;
  glEnable:       procedure(cap: GLenum); cdecl;
  glDisable:      procedure(cap: GLenum); cdecl;
  glDepthFunc:    procedure(func: GLenum); cdecl;
  glDepthMask:    procedure(flag: GLboolean); cdecl;
  glBlendFunc:    procedure(src, dst: GLenum); cdecl;
  glCullFace:     procedure(mode: GLenum); cdecl;
  glFrontFace:    procedure(mode: GLenum); cdecl;
  glViewport:     procedure(x, y: GLint; w, h: GLsizei); cdecl;
  glPolygonOffset:procedure(factor, units: GLfloat); cdecl;
  glGetError:     function: GLenum; cdecl;
  glGetString:    function(name: GLenum): PChar; cdecl;
  glGetIntegerv:  procedure(pname: GLenum; data: PGLint); cdecl;
  glLineWidth:    procedure(w: GLfloat); cdecl;

  { ---- отрисовка ---- }
  glDrawArrays:   procedure(mode: GLenum; first: GLint; count: GLsizei); cdecl;
  glDrawElements: procedure(mode: GLenum; count: GLsizei; typ: GLenum; indices: Pointer); cdecl;
  glDrawElementsInstanced: procedure(mode: GLenum; count: GLsizei; typ: GLenum;
                             indices: Pointer; primcount: GLsizei); cdecl;
  glDrawArraysInstanced: procedure(mode: GLenum; first: GLint; count, primcount: GLsizei); cdecl;

  { ---- закадровый рендер ----
    Нужен и для пост-эффектов, и для проверки движка без экрана:
    рисуем в renderbuffer и читаем пиксели обратно. }
  glFinish:      procedure; cdecl;
  glReadPixels:  procedure(x, y: GLint; width, height: GLsizei;
                           format, typ: GLenum; pixels: Pointer); cdecl;
  glGenFramebuffers:    procedure(n: GLsizei; ids: PGLuint); cdecl;
  glBindFramebuffer:    procedure(target: GLenum; fb: GLuint); cdecl;
  glDeleteFramebuffers: procedure(n: GLsizei; ids: PGLuint); cdecl;
  glGenRenderbuffers:   procedure(n: GLsizei; ids: PGLuint); cdecl;
  glBindRenderbuffer:   procedure(target: GLenum; rb: GLuint); cdecl;
  glDeleteRenderbuffers:procedure(n: GLsizei; ids: PGLuint); cdecl;
  glRenderbufferStorage:procedure(target, internalformat: GLenum;
                                  width, height: GLsizei); cdecl;
  glFramebufferRenderbuffer: procedure(target, attachment, rbtarget: GLenum;
                                       rb: GLuint); cdecl;
  glCheckFramebufferStatus:  function(target: GLenum): GLenum; cdecl;

  { ---- буферы ---- }
  glGenBuffers:    procedure(n: GLsizei; buffers: PGLuint); cdecl;
  glDeleteBuffers: procedure(n: GLsizei; const buffers: PGLuint); cdecl;
  glBindBuffer:    procedure(target: GLenum; buffer: GLuint); cdecl;
  glBufferData:    procedure(target: GLenum; size: GLsizeiptr; const data: Pointer; usage: GLenum); cdecl;
  glBufferSubData: procedure(target: GLenum; offset: GLintptr; size: GLsizeiptr; const data: Pointer); cdecl;
  glMapBufferRange:function(target: GLenum; offset: GLintptr; length: GLsizeiptr; access: GLbitfield): Pointer; cdecl;
  glUnmapBuffer:   function(target: GLenum): GLboolean; cdecl;
  glBindBufferBase:procedure(target: GLenum; index, buffer: GLuint); cdecl;

  { ---- VAO ---- }
  glGenVertexArrays:    procedure(n: GLsizei; arrays: PGLuint); cdecl;
  glDeleteVertexArrays: procedure(n: GLsizei; const arrays: PGLuint); cdecl;
  glBindVertexArray:    procedure(arr: GLuint); cdecl;
  glEnableVertexAttribArray:  procedure(index: GLuint); cdecl;
  glDisableVertexAttribArray: procedure(index: GLuint); cdecl;
  glVertexAttribPointer: procedure(index: GLuint; size: GLint; typ: GLenum;
                           normalized: GLboolean; stride: GLsizei; const ptr: Pointer); cdecl;
  glVertexAttribDivisor: procedure(index, divisor: GLuint); cdecl;

  { ---- шейдеры ---- }
  glCreateShader:  function(typ: GLenum): GLuint; cdecl;
  glDeleteShader:  procedure(shader: GLuint); cdecl;
  glShaderSource:  procedure(shader: GLuint; count: GLsizei; const str: PPChar; const len: PGLint); cdecl;
  glCompileShader: procedure(shader: GLuint); cdecl;
  glGetShaderiv:   procedure(shader: GLuint; pname: GLenum; params: PGLint); cdecl;
  glGetShaderInfoLog: procedure(shader: GLuint; bufsize: GLsizei; len: PGLint; log: PGLchar); cdecl;
  glCreateProgram: function: GLuint; cdecl;
  glDeleteProgram: procedure(prog: GLuint); cdecl;
  glAttachShader:  procedure(prog, shader: GLuint); cdecl;
  glLinkProgram:   procedure(prog: GLuint); cdecl;
  glUseProgram:    procedure(prog: GLuint); cdecl;
  glGetProgramiv:  procedure(prog: GLuint; pname: GLenum; params: PGLint); cdecl;
  glGetProgramInfoLog: procedure(prog: GLuint; bufsize: GLsizei; len: PGLint; log: PGLchar); cdecl;
  glGetUniformLocation: function(prog: GLuint; const name: PGLchar): GLint; cdecl;
  glBindAttribLocation: procedure(prog, index: GLuint; const name: PGLchar); cdecl;
  glUniform1i:     procedure(loc: GLint; v: GLint); cdecl;
  glUniform1f:     procedure(loc: GLint; v: GLfloat); cdecl;
  glUniform2f:     procedure(loc: GLint; a, b: GLfloat); cdecl;
  glUniform3f:     procedure(loc: GLint; a, b, c: GLfloat); cdecl;
  glUniform4f:     procedure(loc: GLint; a, b, c, d: GLfloat); cdecl;
  glUniform3fv:    procedure(loc: GLint; count: GLsizei; const v: PGLfloat); cdecl;
  glUniform4fv:    procedure(loc: GLint; count: GLsizei; const v: PGLfloat); cdecl;
  glUniformMatrix3fv: procedure(loc: GLint; count: GLsizei; transpose: GLboolean; const v: PGLfloat); cdecl;
  glUniformMatrix4fv: procedure(loc: GLint; count: GLsizei; transpose: GLboolean; const v: PGLfloat); cdecl;

  { ---- текстуры ---- }
  glGenTextures:    procedure(n: GLsizei; textures: PGLuint); cdecl;
  glDeleteTextures: procedure(n: GLsizei; const textures: PGLuint); cdecl;
  glBindTexture:    procedure(target: GLenum; texture: GLuint); cdecl;
  glActiveTexture:  procedure(unit_: GLenum); cdecl;
  glTexImage2D:     procedure(target: GLenum; level, internalformat: GLint;
                      w, h: GLsizei; border: GLint; format, typ: GLenum; const pixels: Pointer); cdecl;
  glTexParameteri:  procedure(target: GLenum; pname: GLenum; param: GLint); cdecl;
  glTexParameterf:  procedure(target: GLenum; pname: GLenum; param: GLfloat); cdecl;
  glGenerateMipmap: procedure(target: GLenum); cdecl;

{ Загружает все указатели. Вернёт False, если драйвер не дал критичную
  функцию (значит, контекст не 3.3 Core). }
{ Тип функции, которая отдаёт адрес процедуры OpenGL. Оконная система
  может быть любой: GLFW отдаёт glfwGetProcAddress, headless-проверка на
  EGL -- eglGetProcAddress. Загрузчику всё равно. }
type
  TGLGetProcAddress = function(const name: PChar): Pointer; cdecl;

{ Загрузка через GLFW (обычный путь приложения). }
function gl_load: Boolean;
{ Загрузка через произвольный поставщик адресов (headless-проверки). }
function gl_load_with(getproc: TGLGetProcAddress): Boolean;
function gl_check(const tag: string): Boolean;

implementation

var
  g_missing: Integer = 0;
  g_getproc: TGLGetProcAddress = nil;

function glfw_getproc(const name: PChar): Pointer; cdecl;
begin
  Result := glfwGetProcAddress(name);
end;

function get_proc(const name: string): Pointer;
begin
  Result := g_getproc(PChar(name));
  if Result = nil then
  begin
    Inc(g_missing);
    WriteLn('[gl] не найдена функция: ', name);
  end;
end;

function gl_load: Boolean;
begin
  Result := gl_load_with(@glfw_getproc);
end;

function gl_load_with(getproc: TGLGetProcAddress): Boolean;
begin
  g_getproc := getproc;
  g_missing := 0;

  Pointer(glClear)         := get_proc('glClear');
  Pointer(glClearColor)    := get_proc('glClearColor');
  Pointer(glClearDepth)    := get_proc('glClearDepth');
  Pointer(glEnable)        := get_proc('glEnable');
  Pointer(glDisable)       := get_proc('glDisable');
  Pointer(glDepthFunc)     := get_proc('glDepthFunc');
  Pointer(glDepthMask)     := get_proc('glDepthMask');
  Pointer(glBlendFunc)     := get_proc('glBlendFunc');
  Pointer(glCullFace)      := get_proc('glCullFace');
  Pointer(glFrontFace)     := get_proc('glFrontFace');
  Pointer(glViewport)      := get_proc('glViewport');
  Pointer(glPolygonOffset) := get_proc('glPolygonOffset');
  Pointer(glGetError)      := get_proc('glGetError');
  Pointer(glGetString)     := get_proc('glGetString');
  Pointer(glGetIntegerv)   := get_proc('glGetIntegerv');
  Pointer(glLineWidth)     := get_proc('glLineWidth');

  Pointer(glDrawArrays)    := get_proc('glDrawArrays');
  Pointer(glDrawElements)  := get_proc('glDrawElements');
  Pointer(glDrawElementsInstanced) := get_proc('glDrawElementsInstanced');
  Pointer(glFinish)                  := get_proc('glFinish');
  Pointer(glReadPixels)              := get_proc('glReadPixels');
  Pointer(glGenFramebuffers)         := get_proc('glGenFramebuffers');
  Pointer(glBindFramebuffer)         := get_proc('glBindFramebuffer');
  Pointer(glDeleteFramebuffers)      := get_proc('glDeleteFramebuffers');
  Pointer(glGenRenderbuffers)        := get_proc('glGenRenderbuffers');
  Pointer(glBindRenderbuffer)        := get_proc('glBindRenderbuffer');
  Pointer(glDeleteRenderbuffers)     := get_proc('glDeleteRenderbuffers');
  Pointer(glRenderbufferStorage)     := get_proc('glRenderbufferStorage');
  Pointer(glFramebufferRenderbuffer) := get_proc('glFramebufferRenderbuffer');
  Pointer(glCheckFramebufferStatus)  := get_proc('glCheckFramebufferStatus');
  Pointer(glDrawArraysInstanced)   := get_proc('glDrawArraysInstanced');

  Pointer(glGenBuffers)    := get_proc('glGenBuffers');
  Pointer(glDeleteBuffers) := get_proc('glDeleteBuffers');
  Pointer(glBindBuffer)    := get_proc('glBindBuffer');
  Pointer(glBufferData)    := get_proc('glBufferData');
  Pointer(glBufferSubData) := get_proc('glBufferSubData');
  Pointer(glMapBufferRange):= get_proc('glMapBufferRange');
  Pointer(glUnmapBuffer)   := get_proc('glUnmapBuffer');
  Pointer(glBindBufferBase):= get_proc('glBindBufferBase');

  Pointer(glGenVertexArrays)    := get_proc('glGenVertexArrays');
  Pointer(glDeleteVertexArrays) := get_proc('glDeleteVertexArrays');
  Pointer(glBindVertexArray)    := get_proc('glBindVertexArray');
  Pointer(glEnableVertexAttribArray)  := get_proc('glEnableVertexAttribArray');
  Pointer(glDisableVertexAttribArray) := get_proc('glDisableVertexAttribArray');
  Pointer(glVertexAttribPointer) := get_proc('glVertexAttribPointer');
  Pointer(glVertexAttribDivisor) := get_proc('glVertexAttribDivisor');

  Pointer(glCreateShader)  := get_proc('glCreateShader');
  Pointer(glDeleteShader)  := get_proc('glDeleteShader');
  Pointer(glShaderSource)  := get_proc('glShaderSource');
  Pointer(glCompileShader) := get_proc('glCompileShader');
  Pointer(glGetShaderiv)   := get_proc('glGetShaderiv');
  Pointer(glGetShaderInfoLog) := get_proc('glGetShaderInfoLog');
  Pointer(glCreateProgram) := get_proc('glCreateProgram');
  Pointer(glDeleteProgram) := get_proc('glDeleteProgram');
  Pointer(glAttachShader)  := get_proc('glAttachShader');
  Pointer(glLinkProgram)   := get_proc('glLinkProgram');
  Pointer(glUseProgram)    := get_proc('glUseProgram');
  Pointer(glGetProgramiv)  := get_proc('glGetProgramiv');
  Pointer(glGetProgramInfoLog) := get_proc('glGetProgramInfoLog');
  Pointer(glGetUniformLocation) := get_proc('glGetUniformLocation');
  Pointer(glBindAttribLocation) := get_proc('glBindAttribLocation');
  Pointer(glUniform1i)     := get_proc('glUniform1i');
  Pointer(glUniform1f)     := get_proc('glUniform1f');
  Pointer(glUniform2f)     := get_proc('glUniform2f');
  Pointer(glUniform3f)     := get_proc('glUniform3f');
  Pointer(glUniform4f)     := get_proc('glUniform4f');
  Pointer(glUniform3fv)    := get_proc('glUniform3fv');
  Pointer(glUniform4fv)    := get_proc('glUniform4fv');
  Pointer(glUniformMatrix3fv) := get_proc('glUniformMatrix3fv');
  Pointer(glUniformMatrix4fv) := get_proc('glUniformMatrix4fv');

  Pointer(glGenTextures)    := get_proc('glGenTextures');
  Pointer(glDeleteTextures) := get_proc('glDeleteTextures');
  Pointer(glBindTexture)    := get_proc('glBindTexture');
  Pointer(glActiveTexture)  := get_proc('glActiveTexture');
  Pointer(glTexImage2D)     := get_proc('glTexImage2D');
  Pointer(glTexParameteri)  := get_proc('glTexParameteri');
  Pointer(glTexParameterf)  := get_proc('glTexParameterf');
  Pointer(glGenerateMipmap) := get_proc('glGenerateMipmap');

  Result := g_missing = 0;
end;

function gl_check(const tag: string): Boolean;
var e: GLenum;
begin
  e := glGetError();
  Result := e = GL_NO_ERROR;
  if not Result then
    WriteLn('[gl] ошибка 0x', HexStr(e, 4), ' в ', tag);
end;

end.
