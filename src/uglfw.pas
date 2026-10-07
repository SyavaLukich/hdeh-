{ ============================================================================
  uglfw.pas  --  минимальный биндинг GLFW 3.3

  Описаны только те функции, которые реально нужны движку: создание окна с
  контекстом OpenGL 3.3 Core, ввод, таймер и загрузчик адресов GL-функций.
  Библиотека линкуется динамически по имени, чтобы не тянуть .lib-файлы.
  ============================================================================ }
unit uglfw;

{$MODE OBJFPC}
{$H+}
{$PACKRECORDS C}

interface

const
{$IFDEF WINDOWS}
  GLFW_LIB = 'glfw3.dll';
{$ENDIF}
{$IFDEF LINUX}
  GLFW_LIB = 'libglfw.so.3';
{$ENDIF}
{$IFDEF DARWIN}
  GLFW_LIB = 'libglfw.3.dylib';
{$ENDIF}

const
  GLFW_FALSE = 0;
  GLFW_TRUE  = 1;

  { события }
  GLFW_RELEASE = 0;
  GLFW_PRESS   = 1;
  GLFW_REPEAT  = 2;

  { подсказки при создании окна }
  GLFW_RESIZABLE               = $00020003;
  GLFW_VISIBLE                 = $00020004;
  GLFW_DECORATED               = $00020005;
  GLFW_FOCUSED                 = $00020001;
  GLFW_SAMPLES                 = $0002100D;
  GLFW_SRGB_CAPABLE            = $0002100E;
  GLFW_DOUBLEBUFFER            = $00021010;
  GLFW_RED_BITS                = $00021001;
  GLFW_GREEN_BITS              = $00021002;
  GLFW_BLUE_BITS               = $00021003;
  GLFW_DEPTH_BITS              = $00021005;
  GLFW_STENCIL_BITS            = $00021006;
  GLFW_REFRESH_RATE            = $0002100F;
  GLFW_CONTEXT_VERSION_MAJOR   = $00022002;
  GLFW_CONTEXT_VERSION_MINOR   = $00022003;
  GLFW_OPENGL_FORWARD_COMPAT   = $00022006;
  GLFW_OPENGL_DEBUG_CONTEXT    = $00022007;
  GLFW_OPENGL_PROFILE          = $00022008;
  GLFW_OPENGL_CORE_PROFILE     = $00032001;

  { курсор }
  GLFW_CURSOR          = $00033001;
  GLFW_CURSOR_NORMAL   = $00034001;
  GLFW_CURSOR_HIDDEN   = $00034002;
  GLFW_CURSOR_DISABLED = $00034003;
  GLFW_RAW_MOUSE_MOTION = $00033005;

  { клавиши (подмножество US-раскладки) }
  GLFW_KEY_SPACE        = 32;
  GLFW_KEY_0            = 48;
  GLFW_KEY_1            = 49;
  GLFW_KEY_2            = 50;
  GLFW_KEY_3            = 51;
  GLFW_KEY_4            = 52;
  GLFW_KEY_5            = 53;
  GLFW_KEY_A            = 65;
  GLFW_KEY_B            = 66;
  GLFW_KEY_C            = 67;
  GLFW_KEY_D            = 68;
  GLFW_KEY_E            = 69;
  GLFW_KEY_F            = 70;
  GLFW_KEY_G            = 71;
  GLFW_KEY_P            = 80;
  GLFW_KEY_Q            = 81;
  GLFW_KEY_R            = 82;
  GLFW_KEY_S            = 83;
  GLFW_KEY_T            = 84;
  GLFW_KEY_V            = 86;
  GLFW_KEY_W            = 87;
  GLFW_KEY_X            = 88;
  GLFW_KEY_Z            = 90;
  GLFW_KEY_ESCAPE       = 256;
  GLFW_KEY_ENTER        = 257;
  GLFW_KEY_TAB          = 258;
  GLFW_KEY_RIGHT        = 262;
  GLFW_KEY_LEFT         = 263;
  GLFW_KEY_DOWN         = 264;
  GLFW_KEY_UP           = 265;
  GLFW_KEY_F1           = 290;
  GLFW_KEY_F2           = 291;
  GLFW_KEY_F3           = 292;
  GLFW_KEY_LEFT_SHIFT   = 340;
  GLFW_KEY_LEFT_CONTROL = 341;
  GLFW_KEY_LAST         = 348;

  GLFW_MOUSE_BUTTON_LEFT   = 0;
  GLFW_MOUSE_BUTTON_RIGHT  = 1;
  GLFW_MOUSE_BUTTON_MIDDLE = 2;
  GLFW_MOUSE_BUTTON_LAST   = 7;

type
  PGLFWwindow  = Pointer;
  PGLFWmonitor = Pointer;
  TGLFWglproc  = Pointer;

  TGLFWerrorfun       = procedure(code: Integer; const desc: PChar); cdecl;
  TGLFWframebufferfun = procedure(wnd: PGLFWwindow; w, h: Integer); cdecl;
  TGLFWkeyfun         = procedure(wnd: PGLFWwindow; key, scancode, action, mods: Integer); cdecl;
  TGLFWmousebuttonfun = procedure(wnd: PGLFWwindow; button, action, mods: Integer); cdecl;
  TGLFWcursorposfun   = procedure(wnd: PGLFWwindow; x, y: Double); cdecl;
  TGLFWscrollfun      = procedure(wnd: PGLFWwindow; dx, dy: Double); cdecl;

function  glfwInit: Integer; cdecl; external GLFW_LIB;
procedure glfwTerminate; cdecl; external GLFW_LIB;
procedure glfwWindowHint(hint, value: Integer); cdecl; external GLFW_LIB;
function  glfwCreateWindow(w, h: Integer; const title: PChar;
            mon: PGLFWmonitor; share: PGLFWwindow): PGLFWwindow; cdecl; external GLFW_LIB;
procedure glfwDestroyWindow(wnd: PGLFWwindow); cdecl; external GLFW_LIB;
function  glfwWindowShouldClose(wnd: PGLFWwindow): Integer; cdecl; external GLFW_LIB;
procedure glfwSetWindowShouldClose(wnd: PGLFWwindow; value: Integer); cdecl; external GLFW_LIB;
procedure glfwSetWindowTitle(wnd: PGLFWwindow; const title: PChar); cdecl; external GLFW_LIB;
procedure glfwMakeContextCurrent(wnd: PGLFWwindow); cdecl; external GLFW_LIB;
procedure glfwSwapBuffers(wnd: PGLFWwindow); cdecl; external GLFW_LIB;
procedure glfwSwapInterval(interval: Integer); cdecl; external GLFW_LIB;
procedure glfwPollEvents; cdecl; external GLFW_LIB;
procedure glfwGetFramebufferSize(wnd: PGLFWwindow; var w, h: Integer); cdecl; external GLFW_LIB;
function  glfwGetKey(wnd: PGLFWwindow; key: Integer): Integer; cdecl; external GLFW_LIB;
function  glfwGetMouseButton(wnd: PGLFWwindow; btn: Integer): Integer; cdecl; external GLFW_LIB;
procedure glfwGetCursorPos(wnd: PGLFWwindow; var x, y: Double); cdecl; external GLFW_LIB;
procedure glfwSetCursorPos(wnd: PGLFWwindow; x, y: Double); cdecl; external GLFW_LIB;
procedure glfwSetInputMode(wnd: PGLFWwindow; mode, value: Integer); cdecl; external GLFW_LIB;
function  glfwRawMouseMotionSupported: Integer; cdecl; external GLFW_LIB;
function  glfwGetTime: Double; cdecl; external GLFW_LIB;
procedure glfwSetTime(t: Double); cdecl; external GLFW_LIB;
function  glfwGetProcAddress(const name: PChar): TGLFWglproc; cdecl; external GLFW_LIB;
function  glfwGetPrimaryMonitor: PGLFWmonitor; cdecl; external GLFW_LIB;
function  glfwSetErrorCallback(cb: TGLFWerrorfun): TGLFWerrorfun; cdecl; external GLFW_LIB;
function  glfwSetFramebufferSizeCallback(wnd: PGLFWwindow; cb: TGLFWframebufferfun): TGLFWframebufferfun; cdecl; external GLFW_LIB;
function  glfwSetKeyCallback(wnd: PGLFWwindow; cb: TGLFWkeyfun): TGLFWkeyfun; cdecl; external GLFW_LIB;
function  glfwSetMouseButtonCallback(wnd: PGLFWwindow; cb: TGLFWmousebuttonfun): TGLFWmousebuttonfun; cdecl; external GLFW_LIB;
function  glfwSetCursorPosCallback(wnd: PGLFWwindow; cb: TGLFWcursorposfun): TGLFWcursorposfun; cdecl; external GLFW_LIB;
function  glfwSetScrollCallback(wnd: PGLFWwindow; cb: TGLFWscrollfun): TGLFWscrollfun; cdecl; external GLFW_LIB;

implementation

end.
