{ ============================================================================
  uegl.pas  --  минимальный биндинг EGL для безэкранной проверки

  Нужен ровно для одного: получить настоящий контекст OpenGL там, где нет ни
  дисплея, ни видеокарты. Mesa умеет платформу surfaceless, то есть контекст
  без окна и без поверхности; рисовать в таком контексте можно в
  framebuffer-объект, а потом прочитать пиксели через glReadPixels.

  В самом движке этот модуль не используется -- только в тестах.
  ============================================================================ }
unit uegl;

{$MODE OBJFPC}
{$H+}

interface

uses
  SysUtils;

type
  EGLDisplay = Pointer;
  EGLConfig  = Pointer;
  EGLContext = Pointer;
  EGLSurface = Pointer;
  EGLint     = Integer;
  PEGLint    = ^EGLint;
  PEGLConfig = ^EGLConfig;

const
  EGL_LIB = 'EGL';

  EGL_DEFAULT_DISPLAY = nil;
  EGL_NO_DISPLAY      = nil;
  EGL_NO_CONTEXT      = nil;
  EGL_NO_SURFACE      = nil;

  EGL_FALSE = 0;
  EGL_TRUE  = 1;

  EGL_NONE            = $3038;
  EGL_SURFACE_TYPE    = $3033;
  EGL_PBUFFER_BIT     = $0001;
  EGL_RENDERABLE_TYPE = $3040;
  EGL_OPENGL_BIT      = $0008;
  EGL_RED_SIZE        = $3024;
  EGL_GREEN_SIZE      = $3023;
  EGL_BLUE_SIZE       = $3022;
  EGL_ALPHA_SIZE      = $3021;
  EGL_DEPTH_SIZE      = $3025;

  EGL_OPENGL_API      = $30A2;

  EGL_CONTEXT_MAJOR_VERSION           = $3098;
  EGL_CONTEXT_MINOR_VERSION           = $30FB;
  EGL_CONTEXT_OPENGL_PROFILE_MASK     = $30FD;
  EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT = $00000001;

  EGL_VENDOR  = $3053;
  EGL_VERSION = $3054;

function eglGetDisplay(native: Pointer): EGLDisplay; cdecl; external EGL_LIB;
function eglInitialize(dpy: EGLDisplay; major, minor: PEGLint): EGLint; cdecl; external EGL_LIB;
function eglTerminate(dpy: EGLDisplay): EGLint; cdecl; external EGL_LIB;
function eglBindAPI(api: Cardinal): EGLint; cdecl; external EGL_LIB;
function eglChooseConfig(dpy: EGLDisplay; const attrib: PEGLint;
                         configs: PEGLConfig; size: EGLint;
                         num: PEGLint): EGLint; cdecl; external EGL_LIB;
function eglCreateContext(dpy: EGLDisplay; cfg: EGLConfig; share: EGLContext;
                          const attrib: PEGLint): EGLContext; cdecl; external EGL_LIB;
function eglDestroyContext(dpy: EGLDisplay; ctx: EGLContext): EGLint; cdecl; external EGL_LIB;
function eglMakeCurrent(dpy: EGLDisplay; draw, read: EGLSurface;
                        ctx: EGLContext): EGLint; cdecl; external EGL_LIB;
function eglGetProcAddress(const name: PChar): Pointer; cdecl; external EGL_LIB;
function eglGetError: EGLint; cdecl; external EGL_LIB;
function eglQueryString(dpy: EGLDisplay; name: EGLint): PChar; cdecl; external EGL_LIB;

{ Создаёт контекст OpenGL 3.3 core без окна. Возвращает False с пояснением. }
function egl_headless_init(out msg: string): Boolean;
procedure egl_headless_done;

implementation

var
  g_dpy: EGLDisplay = nil;
  g_ctx: EGLContext = nil;

function egl_headless_init(out msg: string): Boolean;
var
  major, minor, num: EGLint;
  cfg: EGLConfig;
  cfgAttr: array[0..12] of EGLint;
  ctxAttr: array[0..6] of EGLint;
begin
  Result := False;
  msg := '';

  g_dpy := eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if g_dpy = EGL_NO_DISPLAY then
  begin
    msg := 'eglGetDisplay вернул пусто (нет платформы surfaceless?)';
    Exit;
  end;

  if eglInitialize(g_dpy, @major, @minor) = EGL_FALSE then
  begin
    msg := Format('eglInitialize не удался, код %x', [eglGetError]);
    Exit;
  end;

  if eglBindAPI(EGL_OPENGL_API) = EGL_FALSE then
  begin
    msg := 'eglBindAPI(EGL_OPENGL_API) не удался: нет настольного OpenGL';
    Exit;
  end;

  cfgAttr[0] := EGL_SURFACE_TYPE;    cfgAttr[1] := EGL_PBUFFER_BIT;
  cfgAttr[2] := EGL_RENDERABLE_TYPE; cfgAttr[3] := EGL_OPENGL_BIT;
  cfgAttr[4] := EGL_RED_SIZE;        cfgAttr[5] := 8;
  cfgAttr[6] := EGL_GREEN_SIZE;      cfgAttr[7] := 8;
  cfgAttr[8] := EGL_BLUE_SIZE;       cfgAttr[9] := 8;
  cfgAttr[10] := EGL_DEPTH_SIZE;     cfgAttr[11] := 24;
  cfgAttr[12] := EGL_NONE;

  if (eglChooseConfig(g_dpy, @cfgAttr[0], @cfg, 1, @num) = EGL_FALSE) or (num < 1) then
  begin
    msg := 'подходящая конфигурация EGL не найдена';
    Exit;
  end;

  ctxAttr[0] := EGL_CONTEXT_MAJOR_VERSION; ctxAttr[1] := 3;
  ctxAttr[2] := EGL_CONTEXT_MINOR_VERSION; ctxAttr[3] := 3;
  ctxAttr[4] := EGL_CONTEXT_OPENGL_PROFILE_MASK;
  ctxAttr[5] := EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT;
  ctxAttr[6] := EGL_NONE;

  g_ctx := eglCreateContext(g_dpy, cfg, EGL_NO_CONTEXT, @ctxAttr[0]);
  if g_ctx = EGL_NO_CONTEXT then
  begin
    msg := Format('не удалось создать контекст GL 3.3 core, код %x', [eglGetError]);
    Exit;
  end;

  { Контекст без поверхности -- расширение EGL_KHR_surfaceless_context. }
  if eglMakeCurrent(g_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, g_ctx) = EGL_FALSE then
  begin
    msg := Format('eglMakeCurrent без поверхности не удался, код %x', [eglGetError]);
    Exit;
  end;

  msg := Format('EGL %d.%d, %s', [major, minor, eglQueryString(g_dpy, EGL_VENDOR)]);
  Result := True;
end;

procedure egl_headless_done;
begin
  if g_dpy <> nil then
  begin
    eglMakeCurrent(g_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if g_ctx <> nil then eglDestroyContext(g_dpy, g_ctx);
    eglTerminate(g_dpy);
  end;
  g_dpy := nil;
  g_ctx := nil;
end;

end.
