{ ============================================================================
  hdeh-display - display back end interface, input events, input state.

  A display is anything the engine can push finished frames to: the ANSI
  terminal, an SDL window, or the headless display used for off screen
  rendering (screenshots, automated tests, frame dumps).

  Input is expressed as a stream of TInputEvent records.  Back ends that
  cannot report key releases (a terminal only sends bytes, no key up) keep a
  press "held" for InputState.HoldTime seconds and refresh that timer on
  every repeat, which behaves exactly like a key that is held down.
  ============================================================================ }
unit hdeh_display;
{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, hdeh_math, hdeh_image, hdeh_mesh, hdeh_scene, hdeh_raster;

type
  TKey = (kNone, kEscape, kEnter, kTab, kBackspace, kSpace, kDelete,
          kUp, kDown, kLeft, kRight, kPageUp, kPageDown, kHome, kEnd,
          kPlus, kMinus, kF1, kF2, kF3, kF4, kF5);

  TInputEventKind = (ieKeyDown, ieKeyUp, ieMouseMove, ieResize, ieQuit);

  TInputEvent = record
    Kind: TInputEventKind;
    Key: TKey;
    Ch: AnsiChar;
    Shift, Ctrl, Alt: Boolean;
    MouseDX, MouseDY: Single;
    Width, Height: LongInt;
  end;

  TInputState = class
  private
    FKeys: array[TKey] of Boolean;
    FChars: array[0..255] of Boolean;
    FPressed: array[TKey] of Boolean;
    FCharPressed: array[0..255] of Boolean;
    FUntil: array[TKey] of Double;
    FCharUntil: array[0..255] of Double;
    FMouseDX, FMouseDY: Single;
    FShift, FCtrl, FAlt: Boolean;
  public
    HoldTime: Double;          // seconds a press stays "down" without a release
    QuitRequested: Boolean;
    constructor Create;
    procedure Clear;
    procedure HandleEvent(const E: TInputEvent; Now: Double);
    procedure Expire(Now: Double);
    procedure EndFrame;
    function KeyDown(K: TKey): Boolean;
    function CharDown(C: AnsiChar): Boolean;
    function KeyPressed(K: TKey): Boolean;
    function CharPressed(C: AnsiChar): Boolean;
    function TakeMouseDeltaX: Single;
    function TakeMouseDeltaY: Single;
    property ShiftDown: Boolean read FShift;
    property CtrlDown: Boolean read FCtrl;
    property AltDown: Boolean read FAlt;
  end;

  { Time in seconds with sub millisecond resolution (used for frame timing
    and for the input hold timers). }
  function NowSeconds: Double;

  TDisplay = class
  public
    { Open the window / put the terminal into raw mode.  Returns False if the
      display cannot be used, in which case the engine stops immediately. }
    function Init: Boolean; virtual; abstract;
    procedure Shutdown; virtual;
    { Next input event, False when the queue is empty. }
    function PollEvent(out E: TInputEvent): Boolean; virtual; abstract;
    { Show a finished frame. }
    procedure Present(Renderer: TRenderer); virtual; abstract;
    { Framebuffer size in pixels.  For the terminal this is columns x rows*2
      because every character cell holds two vertical pixels. }
    function Width: LongInt; virtual; abstract;
    function Height: LongInt; virtual; abstract;
    function Title: string; virtual;
    procedure SetTitle(const S: string); virtual;
    { True when the display is meant to be looked at by a human. }
    function Interactive: Boolean; virtual;
  end;

  { Off screen display: renders frames, optionally dumps them to disk, never
    reads input.  Handy for screenshots, for the test suite, for time lapse
    renders and for running the demos on machines without a GUI. }
  THeadlessDisplay = class(TDisplay)
  private
    FWidth, FHeight: LongInt;
    FFrames: LongInt;
    FMaxFrames: LongInt;
    FDumpDir: string;
    FDumpPrefix: string;
    FDumpEvery: LongInt;
    FDumpText: Boolean;
    FDumpedCount: LongInt;
  public
    constructor Create(AWidth, AHeight: LongInt);
    function Init: Boolean; override;
    function PollEvent(out E: TInputEvent): Boolean; override;
    procedure Present(Renderer: TRenderer); override;
    function Width: LongInt; override;
    function Height: LongInt; override;

    property MaxFrames: LongInt read FMaxFrames write FMaxFrames;
    property DumpDir: string read FDumpDir write FDumpDir;
    property DumpPrefix: string read FDumpPrefix write FDumpPrefix;
    property DumpEvery: LongInt read FDumpEvery write FDumpEvery;
    property DumpText: Boolean read FDumpText write FDumpText;
    property Frames: LongInt read FFrames;
    property DumpedCount: LongInt read FDumpedCount;
  end;

{ Render a frame buffer as ASCII art (luminance ramp) - used by the
  headless display and by the tests. }
function FrameToText(Renderer: TRenderer; Width, Height: LongInt): string;

implementation

const
  RampChars = ' .:-=+*#%@';

function NowSeconds: Double;
begin
  Result := Now * SecsPerDay;
end;

{ ============================================================ input state == }

constructor TInputState.Create;
begin
  inherited Create;
  HoldTime := 0.25;
  Clear;
end;

procedure TInputState.Clear;
var
  K: TKey;
  I: LongInt;
begin
  for K := Low(TKey) to High(TKey) do
    begin
      FKeys[K] := False;
      FPressed[K] := False;
      FUntil[K] := 0;
    end;
  for I := 0 to 255 do
    begin
      FChars[I] := False;
      FCharPressed[I] := False;
      FCharUntil[I] := 0;
    end;
  FMouseDX := 0;
  FMouseDY := 0;
  FShift := False;
  FCtrl := False;
  FAlt := False;
  QuitRequested := False;
end;

procedure TInputState.HandleEvent(const E: TInputEvent; Now: Double);
var
  C: Byte;
begin
  FShift := E.Shift;
  FCtrl := E.Ctrl;
  FAlt := E.Alt;
  case E.Kind of
    ieKeyDown:
      begin
        if E.Key <> kNone then
          begin
            if not FKeys[E.Key] then FPressed[E.Key] := True;
            FKeys[E.Key] := True;
            FUntil[E.Key] := Now + HoldTime;
          end;
        if E.Ch <> #0 then
          begin
            C := Ord(E.Ch);
            if not FChars[C] then FCharPressed[C] := True;
            FChars[C] := True;
            FCharUntil[C] := Now + HoldTime;
          end;
      end;
    ieKeyUp:
      begin
        if E.Key <> kNone then
          begin
            FKeys[E.Key] := False;
            FUntil[E.Key] := 0;
          end;
        if E.Ch <> #0 then
          begin
            C := Ord(E.Ch);
            FChars[C] := False;
            FCharUntil[C] := 0;
          end;
      end;
    ieMouseMove:
      begin
        FMouseDX := FMouseDX + E.MouseDX;
        FMouseDY := FMouseDY + E.MouseDY;
      end;
    ieQuit:
      QuitRequested := True;
  end;
end;

procedure TInputState.Expire(Now: Double);
var
  K: TKey;
  I: LongInt;
begin
  for K := Low(TKey) to High(TKey) do
    if FUntil[K] > 0 then
      if Now > FUntil[K] then
        begin
          FKeys[K] := False;
          FUntil[K] := 0;
        end;
  for I := 0 to 255 do
    if FCharUntil[I] > 0 then
      if Now > FCharUntil[I] then
        begin
          FChars[I] := False;
          FCharUntil[I] := 0;
        end;
end;

procedure TInputState.EndFrame;
var
  K: TKey;
  I: LongInt;
begin
  for K := Low(TKey) to High(TKey) do
    FPressed[K] := False;
  for I := 0 to 255 do
    FCharPressed[I] := False;
  FMouseDX := 0;
  FMouseDY := 0;
end;

function TInputState.KeyDown(K: TKey): Boolean;
begin
  Result := FKeys[K];
end;

function TInputState.CharDown(C: AnsiChar): Boolean;
begin
  Result := FChars[Ord(C)];
end;

function TInputState.KeyPressed(K: TKey): Boolean;
begin
  Result := FPressed[K];
end;

function TInputState.CharPressed(C: AnsiChar): Boolean;
begin
  Result := FCharPressed[Ord(C)];
end;

function TInputState.TakeMouseDeltaX: Single;
begin
  Result := FMouseDX;
end;

function TInputState.TakeMouseDeltaY: Single;
begin
  Result := FMouseDY;
end;

{ ================================================================ display == }

function TDisplay.Title: string;
begin
  Result := '';
end;

procedure TDisplay.SetTitle(const S: string);
begin
  // nothing by default
end;

procedure TDisplay.Shutdown;
begin
  // nothing by default
end;

function TDisplay.Interactive: Boolean;
begin
  Result := False;
end;

{ ======================================================= headless display == }

constructor THeadlessDisplay.Create(AWidth, AHeight: LongInt);
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  FMaxFrames := 1;
  FDumpDir := '';
  FDumpPrefix := 'frame';
  FDumpEvery := 1;
  FDumpText := True;
  FFrames := 0;
  FDumpedCount := 0;
end;

function THeadlessDisplay.Init: Boolean;
begin
  Result := (FWidth > 0) and (FHeight > 0);
  if Result and (FDumpDir <> '') then
    ForceDirectories(FDumpDir);
end;

function THeadlessDisplay.PollEvent(out E: TInputEvent): Boolean;
begin
  FillChar(E, SizeOf(E), 0);
  Result := False;
end;

function THeadlessDisplay.Width: LongInt;
begin
  Result := FWidth;
end;

function THeadlessDisplay.Height: LongInt;
begin
  Result := FHeight;
end;

procedure THeadlessDisplay.Present(Renderer: TRenderer);
var
  Img: TImage;
  Path: string;
  Txt: TStrings;
begin
  Inc(FFrames);
  if (FDumpDir <> '') and (FDumpEvery > 0) and ((FFrames - 1) mod FDumpEvery = 0) then
    begin
      Path := IncludeTrailingPathDelimiter(FDumpDir) + FDumpPrefix +
              Format('%.4d', [FFrames]);
      Img := TImage.Create(Renderer.Width, Renderer.Height);
      try
        Renderer.ToImage(Img);
        Img.SavePPM(Path + '.ppm');
      finally
        Img.Free;
      end;
      if FDumpText then
        begin
          Txt := TStringList.Create;
          try
            Txt.Text := FrameToText(Renderer, Renderer.Width, Renderer.Height div 8);
            Txt.SaveToFile(Path + '.txt');
          finally
            Txt.Free;
          end;
        end;
      Inc(FDumpedCount);
    end;
end;

function FrameToText(Renderer: TRenderer; Width, Height: LongInt): string;
{ ASCII art preview of the frame buffer: one character per WxH block. }
var
  SX, SY, X, Y, I, Lum: LongInt;
  C: TVec3;
  R: string;
begin
  if Width < 1 then Width := 40;
  if Height < 1 then Height := 15;
  Result := '';
  for SY := 0 to Height - 1 do
    begin
      R := '';
      for SX := 0 to Width - 1 do
        begin
          C := Vec3Zero;
          for Y := SY * Renderer.Height div Height to (SY + 1) * Renderer.Height div Height - 1 do
            for X := SX * Renderer.Width div Width to (SX + 1) * Renderer.Width div Width - 1 do
              C := C + Renderer.ColorAt(X, Y);
          Lum := Round((C.X + C.Y + C.Z) / 3 * 255 /
                 Max(1, (Renderer.Width div Width) * (Renderer.Height div Height)));
          I := Lum * 9 div 255;
          if I < 0 then I := 0;
          if I > 9 then I := 9;
          R := R + RampChars[I + 1];
        end;
      Result := Result + R + #10;
    end;
end;

end.
