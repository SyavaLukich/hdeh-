{ ============================================================================
  hdeh-sdl2 - display back end for a real window (SDL2), plus the small
  SDL2 binding it needs.

  Only the handful of SDL2 entry points the engine uses are declared here,
  so no external Pascal SDL2 package is required - libSDL2-2.0.so.0 (the
  normal runtime library of every distribution) is all you need.

  The frame buffer is uploaded into a streaming texture once per frame and
  blitted to the window with linear filtering, so rendering at e.g. 480x300
  and showing it in a 1280x800 window gives a pleasantly soft image and
  keeps the software rasterizer fast.
  ============================================================================ }
unit hdeh_sdl2;
{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, hdeh_math, hdeh_image, hdeh_raster, hdeh_display;

const
  SDLLib = 'libSDL2-2.0.so.0';

  SDL_INIT_VIDEO = $00000020;
  SDL_WINDOWPOS_CENTERED = $2FFF0000;
  SDL_WINDOW_SHOWN = $00000004;
  SDL_WINDOW_RESIZABLE = $00000020;
  SDL_RENDERER_ACCELERATED = $00000002;
  SDL_RENDERER_PRESENTVSYNC = $00000004;
  SDL_PIXELFORMAT_ABGR8888 = $16762004;
  SDL_TEXTUREACCESS_STREAMING = 1;
  SDL_BLENDMODE_NONE = 0;

  SDL_QUIT_EVENT = $100;
  SDL_WINDOWEVENT = $200;
  SDL_KEYDOWN = $300;
  SDL_KEYUP = $301;
  SDL_MOUSEMOTION = $400;
  SDL_WINDOWEVENT_RESIZED = 5;
  SDL_WINDOWEVENT_SIZE_CHANGED = 6;

  SDLK_TAB = 9;
  SDLK_RETURN = 13;
  SDLK_ESCAPE = 27;
  SDLK_SPACE = 32;
  SDLK_BACKSPACE = 8;
  SDLK_DELETE = 127;
  SDLK_UP = $40000052;
  SDLK_DOWN = $40000051;
  SDLK_LEFT = $40000050;
  SDLK_RIGHT = $4000004F;
  SDLK_PAGEUP = $4000004B;
  SDLK_PAGEDOWN = $4000004E;
  SDLK_HOME = $4000004A;
  SDLK_END = $4000004D;
  SDLK_F1 = $4000003A;

  KMOD_LSHIFT = $0001;
  KMOD_RSHIFT = $0002;
  KMOD_LCTRL = $0040;
  KMOD_RCTRL = $0080;
  KMOD_LALT = $0100;
  KMOD_RALT = $0200;

type
  PSDL_Window = Pointer;
  PSDL_Renderer = Pointer;
  PSDL_Texture = Pointer;

  TSDL_Rect = record
    X, Y, W, H: LongInt;
  end;

{$PACKRECORDS C}
  TSDL_Keysym = record
    Scancode: LongInt;
    Sym: LongInt;
    Modifier: Word;
    Unused: LongWord;
  end;

  TSDL_KeyboardEvent = record
    Typ: LongWord;
    TimeStamp: LongWord;
    WindowID: LongWord;
    State: Byte;
    Repeat_: Byte;
    Padding2: Byte;
    Padding3: Byte;
    Keysym: TSDL_Keysym;
  end;

  TSDL_WindowEvent = record
    Typ: LongWord;
    TimeStamp: LongWord;
    WindowID: LongWord;
    Event: Byte;
    Padding1: Byte;
    Padding2: Byte;
    Padding3: Byte;
    Data1: LongInt;
    Data2: LongInt;
  end;

  TSDL_MouseMotionEvent = record
    Typ: LongWord;
    TimeStamp: LongWord;
    WindowID: LongWord;
    Which: LongWord;
    State: LongWord;
    X, Y: LongInt;
    XRel, YRel: LongInt;
  end;

  TSDL_Event = record
    Typ: LongWord;
    Padding: array[0..51] of Byte;
  end;
{$PACKRECORDS DEFAULT}

function SDL_Init(Flags: LongWord): LongInt; cdecl; external SDLLib;
procedure SDL_Quit; cdecl; external SDLLib;
function SDL_GetError: PAnsiChar; cdecl; external SDLLib;
function SDL_SetHint(Name: PAnsiChar; Value: PAnsiChar): LongBool; cdecl; external SDLLib;
function SDL_CreateWindow(Title: PAnsiChar; X, Y, W, H: LongInt;
  Flags: LongWord): PSDL_Window; cdecl; external SDLLib;
procedure SDL_DestroyWindow(Window: PSDL_Window); cdecl; external SDLLib;
procedure SDL_SetWindowTitle(Window: PSDL_Window; Title: PAnsiChar); cdecl; external SDLLib;
function SDL_GetWindowSize(Window: PSDL_Window; out W, H: LongInt): LongInt; cdecl; external SDLLib;
function SDL_CreateRenderer(Window: PSDL_Window; Index: LongInt;
  Flags: LongWord): PSDL_Renderer; cdecl; external SDLLib;
procedure SDL_DestroyRenderer(Renderer: PSDL_Renderer); cdecl; external SDLLib;
function SDL_SetRenderDrawColor(Renderer: PSDL_Renderer; R, G, B, A: Byte): LongInt; cdecl; external SDLLib;
function SDL_RenderClear(Renderer: PSDL_Renderer): LongInt; cdecl; external SDLLib;
function SDL_RenderCopy(Renderer: PSDL_Renderer; Texture: PSDL_Texture;
  SrcRect, DstRect: PSDL_Rect): LongInt; cdecl; external SDLLib;
procedure SDL_RenderPresent(Renderer: PSDL_Renderer); cdecl; external SDLLib;
function SDL_CreateTexture(Renderer: PSDL_Renderer; Format: LongWord;
  Access, W, H: LongInt): PSDL_Texture; cdecl; external SDLLib;
procedure SDL_DestroyTexture(Texture: PSDL_Texture); cdecl; external SDLLib;
function SDL_UpdateTexture(Texture: PSDL_Texture; Rect: PSDL_Rect;
  Pixels: Pointer; Pitch: LongInt): LongInt; cdecl; external SDLLib;
function SDL_PollEvent(out Event: TSDL_Event): LongInt; cdecl; external SDLLib;
function SDL_SetRelativeMouseMode(Enabled: LongBool): LongInt; cdecl; external SDLLib;
procedure SDL_Delay(Ms: LongWord); cdecl; external SDLLib;
function SDL_GetTicks: LongWord; cdecl; external SDLLib;

type
  TSDL2Display = class(TDisplay)
  private
    FWindow: PSDL_Window;
    FRenderer: PSDL_Renderer;
    FTexture: PSDL_Texture;
    FWidth, FHeight: LongInt;
    FPixels: array of TRGBA;
    FTitle: string;
    FVSync: Boolean;
    FInited: Boolean;
    FMouseLook: Boolean;
    FMouseCaptured: Boolean;
  public
    constructor Create(AWidth, AHeight: LongInt; const ATitle: string;
      AVSync: Boolean = True);
    destructor Destroy; override;

    function Init: Boolean; override;
    procedure Shutdown; override;
    function PollEvent(out E: TInputEvent): Boolean; override;
    procedure Present(Renderer: TRenderer); override;
    function Width: LongInt; override;
    function Height: LongInt; override;
    function Interactive: Boolean; override;
    procedure SetTitle(const S: string); override;

    property Window: PSDL_Window read FWindow;
    property Renderer: PSDL_Renderer read FRenderer;
    { relative mouse mode: the cursor is hidden and mouse motion is reported
      as deltas, which is what a free camera wants }
    property MouseLook: Boolean read FMouseLook write FMouseLook;
  end;

function SDLKeyToKey(Sym: LongInt; out Ch: AnsiChar): TKey;

implementation

function SDLKeyToKey(Sym: LongInt; out Ch: AnsiChar): TKey;
begin
  Ch := #0;
  Result := kNone;
  case Sym of
    SDLK_ESCAPE: Result := kEscape;
    SDLK_RETURN: Result := kEnter;
    SDLK_TAB: Result := kTab;
    SDLK_BACKSPACE: Result := kBackspace;
    SDLK_DELETE: Result := kDelete;
    SDLK_SPACE: begin Result := kSpace; Ch := ' '; end;
    SDLK_UP: Result := kUp;
    SDLK_DOWN: Result := kDown;
    SDLK_LEFT: Result := kLeft;
    SDLK_RIGHT: Result := kRight;
    SDLK_PAGEUP: Result := kPageUp;
    SDLK_PAGEDOWN: Result := kPageDown;
    SDLK_HOME: Result := kHome;
    SDLK_END: Result := kEnd;
    SDLK_F1: Result := kF1;
    43: begin Result := kPlus; Ch := '+'; end;
    45: begin Result := kMinus; Ch := '-'; end;
    61: begin Result := kPlus; Ch := '='; end;
    95: begin Result := kMinus; Ch := '_'; end;
    else
      if (Sym >= 32) and (Sym < 127) then
        Ch := AnsiChar(Sym);
  end;
end;

constructor TSDL2Display.Create(AWidth, AHeight: LongInt; const ATitle: string;
  AVSync: Boolean);
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  FTitle := ATitle;
  FVSync := AVSync;
  FInited := False;
  FMouseLook := True;
  FMouseCaptured := False;
  FWindow := nil;
  FRenderer := nil;
  FTexture := nil;
end;

destructor TSDL2Display.Destroy;
begin
  Shutdown;
  inherited Destroy;
end;

function TSDL2Display.Init: Boolean;
var
  Flags: LongWord;
begin
  Result := False;
  if SDL_Init(SDL_INIT_VIDEO) <> 0 then
    begin
      WriteLn(StdErr, 'SDL_Init failed: ', SDL_GetError);
      Exit;
    end;

  Flags := SDL_WINDOW_SHOWN or SDL_WINDOW_RESIZABLE;
  FWindow := SDL_CreateWindow(PAnsiChar(AnsiString(FTitle)), SDL_WINDOWPOS_CENTERED,
    SDL_WINDOWPOS_CENTERED, FWidth, FHeight, Flags);
  if FWindow = nil then
    begin
      WriteLn(StdErr, 'SDL_CreateWindow failed: ', SDL_GetError);
      SDL_Quit;
      Exit;
    end;

  Flags := SDL_RENDERER_ACCELERATED;
  if FVSync then Flags := Flags or SDL_RENDERER_PRESENTVSYNC;
  FRenderer := SDL_CreateRenderer(FWindow, -1, Flags);
  if FRenderer = nil then
    FRenderer := SDL_CreateRenderer(FWindow, -1, 0);   // software fallback
  if FRenderer = nil then
    begin
      WriteLn(StdErr, 'SDL_CreateRenderer failed: ', SDL_GetError);
      Exit;
    end;

  SDL_SetHint('SDL_RENDER_SCALE_QUALITY', '1');        // linear filtering
  SDL_SetRenderDrawColor(FRenderer, 0, 0, 0, 255);

  FTexture := SDL_CreateTexture(FRenderer, SDL_PIXELFORMAT_ABGR8888,
    SDL_TEXTUREACCESS_STREAMING, FWidth, FHeight);
  if FTexture = nil then
    begin
      WriteLn(StdErr, 'SDL_CreateTexture failed: ', SDL_GetError);
      Exit;
    end;

  SetLength(FPixels, FWidth * FHeight);
  if FMouseLook then
    begin
      FMouseCaptured := SDL_SetRelativeMouseMode(True) = 0;
    end;
  FInited := True;
  Result := True;
end;

procedure TSDL2Display.Shutdown;
begin
  if not FInited then Exit;
  if FMouseCaptured then
    SDL_SetRelativeMouseMode(False);
  if FTexture <> nil then
    begin
      SDL_DestroyTexture(FTexture);
      FTexture := nil;
    end;
  if FRenderer <> nil then
    begin
      SDL_DestroyRenderer(FRenderer);
      FRenderer := nil;
    end;
  if FWindow <> nil then
    begin
      SDL_DestroyWindow(FWindow);
      FWindow := nil;
    end;
  SDL_Quit;
  FInited := False;
end;

function TSDL2Display.Interactive: Boolean;
begin
  Result := FInited;
end;

function TSDL2Display.Width: LongInt;
begin
  Result := FWidth;
end;

function TSDL2Display.Height: LongInt;
begin
  Result := FHeight;
end;

procedure TSDL2Display.SetTitle(const S: string);
begin
  FTitle := S;
  if FWindow <> nil then
    SDL_SetWindowTitle(FWindow, PAnsiChar(AnsiString(S)));
end;

function TSDL2Display.PollEvent(out E: TInputEvent): Boolean;
var
  Ev: TSDL_Event;
  KB: TSDL_KeyboardEvent;
  WE: TSDL_WindowEvent;
  MM: TSDL_MouseMotionEvent;
  Ch: AnsiChar;
  WW, HH: LongInt;
begin
  Result := False;
  FillChar(E, SizeOf(E), 0);
  if not FInited then Exit;

  if SDL_PollEvent(Ev) = 0 then Exit;

  case Ev.Typ of
    SDL_QUIT_EVENT:
      E.Kind := ieQuit;
    SDL_WINDOWEVENT:
      begin
        WE := TSDL_WindowEvent(Ev);
        if (WE.Event = SDL_WINDOWEVENT_RESIZED) or (WE.Event = SDL_WINDOWEVENT_SIZE_CHANGED) then
          begin
            if SDL_GetWindowSize(FWindow, WW, HH) = 0 then
              begin
                if WW > 0 then FWidth := WW;
                if HH > 0 then FHeight := HH;
              end;
            E.Kind := ieResize;
            E.Width := FWidth;
            E.Height := FHeight;
          end
        else
          Exit;
      end;
    SDL_KEYDOWN, SDL_KEYUP:
      begin
        KB := TSDL_KeyboardEvent(Ev);
        E.Key := SDLKeyToKey(KB.Keysym.Sym, Ch);
        E.Ch := Ch;
        E.Shift := (KB.Keysym.Modifier and (KMOD_LSHIFT or KMOD_RSHIFT)) <> 0;
        E.Ctrl := (KB.Keysym.Modifier and (KMOD_LCTRL or KMOD_RCTRL)) <> 0;
        E.Alt := (KB.Keysym.Modifier and (KMOD_LALT or KMOD_RALT)) <> 0;
        if Ev.Typ = SDL_KEYDOWN then E.Kind := ieKeyDown else E.Kind := ieKeyUp;
      end;
    SDL_MOUSEMOTION:
      begin
        MM := TSDL_MouseMotionEvent(Ev);
        E.Kind := ieMouseMove;
        E.MouseDX := MM.XRel;
        E.MouseDY := MM.YRel;
      end;
    else
      Exit;
  end;
  Result := True;
end;

procedure TSDL2Display.Present(Renderer: TRenderer);
var
  X, Y, WinW, WinH: LongInt;
  Src, Dst: TSDL_Rect;
  Scale: Single;
begin
  if not FInited then Exit;
  if (FWidth <> Renderer.Width) or (FHeight <> Renderer.Height) then
    begin
      FWidth := Renderer.Width;
      FHeight := Renderer.Height;
      if FTexture <> nil then SDL_DestroyTexture(FTexture);
      FTexture := SDL_CreateTexture(FRenderer, SDL_PIXELFORMAT_ABGR8888,
        SDL_TEXTUREACCESS_STREAMING, FWidth, FHeight);
      SetLength(FPixels, FWidth * FHeight);
      if FTexture = nil then Exit;
    end;

  for Y := 0 to FHeight - 1 do
    for X := 0 to FWidth - 1 do
      FPixels[Y * FWidth + X] := RGBAFromVec(Renderer.ColorAt(X, Y));

  SDL_UpdateTexture(FTexture, nil, @FPixels[0], FWidth * SizeOf(TRGBA));

  WinW := FWidth;
  WinH := FHeight;
  SDL_GetWindowSize(FWindow, WinW, WinH);

  // keep the aspect ratio: letterbox the frame in the window
  Src.X := 0;
  Src.Y := 0;
  Src.W := FWidth;
  Src.H := FHeight;
  Scale := MinS(WinW / FWidth, WinH / FHeight);
  Dst.W := Round(FWidth * Scale);
  Dst.H := Round(FHeight * Scale);
  Dst.X := (WinW - Dst.W) div 2;
  Dst.Y := (WinH - Dst.H) div 2;

  SDL_SetRenderDrawColor(FRenderer, 8, 8, 12, 255);
  SDL_RenderClear(FRenderer);
  SDL_RenderCopy(FRenderer, FTexture, @Src, @Dst);
  SDL_RenderPresent(FRenderer);
end;

end.
