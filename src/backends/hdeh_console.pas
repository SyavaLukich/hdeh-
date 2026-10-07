{ ============================================================================
  hdeh-console - display back end for ANSI terminals (Linux/Unix).

  Every character cell shows two independent pixels using the UPPER HALF
  BLOCK glyph: the foreground colour paints the upper pixel, the background
  colour the lower one.  A 100x30 terminal therefore gives a 100x58 pixel
  frame buffer, and since terminal cells are roughly twice as tall as they
  are wide the pixels come out nearly square.

  Colour depth is picked automatically from the environment:
      truecolor    when $COLORTERM says so
      256 colours  for xterm alike terminals
      16 colours   for the classics
      ASCII ramp   when there is no terminal at all (pipes, files, CI logs)

  Input is read in raw mode.  A terminal cannot report key releases, so a
  press stays "held" for InputState.HoldTime seconds and is refreshed by the
  auto repeat of the terminal - which behaves like a held key.  Ctrl+C and
  Ctrl+D quit.
  ============================================================================ }
unit hdeh_console;
{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, BaseUnix, termio,
  hdeh_math, hdeh_image, hdeh_raster, hdeh_display;

type
  TColorMode = (cmTrueColor, cm256, cm16, cmMono);

  TConsoleDisplay = class(TDisplay)
  private
    FCols, FRows: LongInt;
    FStatusRows: LongInt;
    FColorMode: TColorMode;
    FRawMode: Boolean;
    FOldTermios: TermIOS;
    FNeedsClear: Boolean;
    FTitle: string;
    FPollCounter: LongInt;
    FOverlay: TStringList;
    FStatus: string;
    FQueue: array[0..63] of TInputEvent;
    FQueueHead, FQueueCount: LongInt;
    FBuf: AnsiString;
    procedure QueryTerminalSize;
    procedure QueueEvent(const E: TInputEvent);
    procedure PushKey(K: TKey; Ch: AnsiChar);
    procedure PushQuit;
    procedure HandleBytes(const Buf: array of Byte; Count: LongInt);
    procedure HandleEscape;
    function ReadByteTimeout(out B: Byte; Ms: LongInt): Boolean;
    function CanRead(Ms: LongInt): Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    function Init: Boolean; override;
    procedure Shutdown; override;
    function PollEvent(out E: TInputEvent): Boolean; override;
    procedure Present(Renderer: TRenderer); override;
    function Width: LongInt; override;
    function Height: LongInt; override;
    function Interactive: Boolean; override;
    procedure SetTitle(const S: string); override;

    procedure ResizeToTerminal;
    procedure ClearScreen;
    procedure WriteRaw(const S: string);

    property Cols: LongInt read FCols;
    property Rows: LongInt read FRows;
    { terminal rows at the bottom used for plain text, they are not part of
      the pixel area }
    property StatusRows: LongInt read FStatusRows write FStatusRows;
    property ColorMode: TColorMode read FColorMode write FColorMode;
    { text drawn on top of the pixel area (help screen, messages) }
    property Overlay: TStringList read FOverlay;
    { single line of plain text shown in the status rows }
    property Status: string read FStatus write FStatus;
  end;

function DetectColorMode: TColorMode;
function RGBTo256(R, G, B: Byte): Byte;
function RGBTo16(R, G, B: Byte): Byte;

implementation

const
  ESC = #27;
  Ramp: array[0..9] of Char = (' ', '.', ':', '-', '=', '+', '*', '#', '%', '@');
  HalfBlock = #226#150#128;      // U+2580 in UTF-8

{ -------------------------------------------------------------- strings --- }

procedure BufAppend(var Buf: AnsiString; var Pos: LongInt; const S: string);
var
  Need: LongInt;
begin
  if S = '' then Exit;
  Need := Pos + Length(S);
  if Need > Length(Buf) then
    SetLength(Buf, Need * 2 + 256);
  Move(S[1], Buf[Pos + 1], Length(S));
  Inc(Pos, Length(S));
end;

procedure BufAppendChar(var Buf: AnsiString; var Pos: LongInt; C: AnsiChar);
var
  Need: LongInt;
begin
  Need := Pos + 1;
  if Need > Length(Buf) then
    SetLength(Buf, Need * 2 + 256);
  Buf[Pos + 1] := C;
  Inc(Pos);
end;

procedure BufAppendInt(var Buf: AnsiString; var Pos: LongInt; V: LongInt);
begin
  BufAppend(Buf, Pos, IntToStr(V));
end;

{ ------------------------------------------------------------- palette ---- }

function RGBTo256(R, G, B: Byte): Byte;
var
  Grey, GreyIdx, CR, CG, CB, CubeDist, GreyDist: LongInt;
begin
  CR := (R * 5) div 255;
  CG := (G * 5) div 255;
  CB := (B * 5) div 255;
  Grey := (Integer(R) * 30 + Integer(G) * 59 + Integer(B) * 11) div 100;
  if Grey < 8 then
    GreyIdx := 16
  else
    GreyIdx := 232 + (Grey - 8 + 5) div 10;
  if GreyIdx > 255 then GreyIdx := 255;

  if (R = G) and (G = B) then
    Exit(Byte(GreyIdx));

  CubeDist := Abs(R - CR * 51) + Abs(G - CG * 51) + Abs(B - CB * 51);
  GreyDist := Abs(R - Grey) + Abs(G - Grey) + Abs(B - Grey);
  if CubeDist <= GreyDist then
    Result := Byte(16 + 36 * CR + 6 * CG + CB)
  else
    Result := Byte(GreyIdx);
end;

function RGBTo16(R, G, B: Byte): Byte;
const
  Pal: array[0..15] of array[0..2] of Byte =
    ((0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
     (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
     (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
     (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255));
var
  I, Best, BestDist, Dist: LongInt;
begin
  Best := 0;
  BestDist := MaxInt;
  for I := 0 to 15 do
    begin
      Dist := Sqr(Integer(R) - Pal[I][0]) + Sqr(Integer(G) - Pal[I][1]) +
              Sqr(Integer(B) - Pal[I][2]);
      if Dist < BestDist then
        begin
          BestDist := Dist;
          Best := I;
        end;
    end;
  Result := Best;
end;

function DetectColorMode: TColorMode;
var
  CT, Term: string;
begin
  CT := LowerCase(GetEnvironmentVariable('COLORTERM'));
  Term := LowerCase(GetEnvironmentVariable('TERM'));
  if (Pos('truecolor', CT) > 0) or (Pos('24bit', CT) > 0) then
    Exit(cmTrueColor);
  if (Pos('256', Term) > 0) or (Pos('kitty', Term) > 0) or
     (Pos('alacritty', Term) > 0) or (Pos('wezterm', Term) > 0) then
    Exit(cm256);
  if (Term = '') or (Term = 'dumb') then
    Exit(cmMono);
  Result := cm16;
end;

{ ================================================================ display == }

constructor TConsoleDisplay.Create;
begin
  inherited Create;
  FCols := 80;
  FRows := 24;
  FStatusRows := 0;
  FColorMode := DetectColorMode;
  FRawMode := False;
  FNeedsClear := True;
  FPollCounter := 0;
  FQueueHead := 0;
  FQueueCount := 0;
  FOverlay := TStringList.Create;
  FStatus := '';
  FTitle := '';
end;

destructor TConsoleDisplay.Destroy;
begin
  FOverlay.Free;
  inherited Destroy;
end;

function TConsoleDisplay.Init: Boolean;
var
  T: TermIOS;
begin
  Result := False;
  QueryTerminalSize;

  if IsATTY(1) = 0 then
    begin
      { not a terminal (pipe, file, CI log): render anyway, without ANSI }
      FColorMode := cmMono;
      FRawMode := False;
      Exit(True);
    end;

  if TCGetAttr(0, T) <> 0 then
    Exit(False);
  FOldTermios := T;
  CFMakeRaw(T);
  if TCSetAttr(0, TCSANOW, T) <> 0 then
    Exit(False);
  FRawMode := True;

  WriteRaw(ESC + '[?1049h' + ESC + '[?25l' + ESC + '[2J');
  Result := True;
end;

procedure TConsoleDisplay.Shutdown;
begin
  if FRawMode then
    begin
      WriteRaw(ESC + '[0m' + ESC + '[?25h' + ESC + '[?1049l');
      TCSetAttr(0, TCSANOW, FOldTermios);
      FRawMode := False;
    end;
end;

function TConsoleDisplay.Interactive: Boolean;
begin
  Result := FRawMode;
end;

function TConsoleDisplay.Width: LongInt;
begin
  Result := FCols;
end;

function TConsoleDisplay.Height: LongInt;
{ two pixels per character cell (upper half block) }
begin
  Result := (FRows - FStatusRows) * 2;
  if Result < 2 then Result := 2;
end;

procedure TConsoleDisplay.SetTitle(const S: string);
begin
  FTitle := S;
  if FRawMode then
    WriteRaw(ESC + ']0;' + S + #7);
end;

procedure TConsoleDisplay.QueryTerminalSize;
var
  WS: TWinSize;
  C, R: LongInt;
begin
  C := 0;
  R := 0;
  FillChar(WS, SizeOf(WS), 0);
  if fpIOCtl(1, TIOCtlRequest(TIOCGWINSZ), @WS) = 0 then
    if (WS.ws_col > 0) and (WS.ws_row > 0) then
      begin
        C := WS.ws_col;
        R := WS.ws_row;
      end;
  if (C = 0) or (R = 0) then
    begin
      C := StrToIntDef(GetEnvironmentVariable('COLUMNS'), 0);
      R := StrToIntDef(GetEnvironmentVariable('LINES'), 0);
    end;
  if (C > 0) and (R > 0) then
    begin
      FCols := C;
      FRows := R;
    end;
end;

procedure TConsoleDisplay.ResizeToTerminal;
var
  OldC, OldR: LongInt;
begin
  OldC := FCols;
  OldR := FRows;
  QueryTerminalSize;
  if (OldC <> FCols) or (OldR <> FRows) then
      FNeedsClear := True;
end;

procedure TConsoleDisplay.WriteRaw(const S: string);
begin
  if Length(S) = 0 then Exit;
  fpWrite(1, S[1], Length(S));
end;

procedure TConsoleDisplay.ClearScreen;
begin
  WriteRaw(ESC + '[2J' + ESC + '[1;1H');
end;

{ ================================================================ present == }

procedure AppendColor(var Buf: AnsiString; var Pos: LongInt;
  Mode: TColorMode; FG, BG: TRGBA);
var
  F, B: LongInt;
begin
  case Mode of
    cmTrueColor:
      begin
        BufAppend(Buf, Pos, ESC + '[38;2;');
        BufAppendInt(Buf, Pos, FG.R); BufAppendChar(Buf, Pos, ';');
        BufAppendInt(Buf, Pos, FG.G); BufAppendChar(Buf, Pos, ';');
        BufAppendInt(Buf, Pos, FG.B); BufAppendChar(Buf, Pos, 'm');
        BufAppend(Buf, Pos, ESC + '[48;2;');
        BufAppendInt(Buf, Pos, BG.R); BufAppendChar(Buf, Pos, ';');
        BufAppendInt(Buf, Pos, BG.G); BufAppendChar(Buf, Pos, ';');
        BufAppendInt(Buf, Pos, BG.B); BufAppendChar(Buf, Pos, 'm');
      end;
    cm256:
      begin
        F := RGBTo256(FG.R, FG.G, FG.B);
        B := RGBTo256(BG.R, BG.G, BG.B);
        BufAppend(Buf, Pos, ESC + '[38;5;'); BufAppendInt(Buf, Pos, F);
        BufAppendChar(Buf, Pos, 'm');
        BufAppend(Buf, Pos, ESC + '[48;5;'); BufAppendInt(Buf, Pos, B);
        BufAppendChar(Buf, Pos, 'm');
      end;
    cm16:
      begin
        F := RGBTo16(FG.R, FG.G, FG.B);
        B := RGBTo16(BG.R, BG.G, BG.B);
        if F < 8 then
          BufAppend(Buf, Pos, ESC + '[3' + IntToStr(F) + 'm')
        else
          BufAppend(Buf, Pos, ESC + '[9' + IntToStr(F - 8) + 'm');
        if B < 8 then
          BufAppend(Buf, Pos, ESC + '[4' + IntToStr(B) + 'm')
        else
          BufAppend(Buf, Pos, ESC + '[10' + IntToStr(B - 8) + 'm');
      end;
  end;
end;

procedure TConsoleDisplay.Present(Renderer: TRenderer);
var
  Pos, X, Row, Rows, Lum, Idx: LongInt;
  Top, Bottom: TRGBA;
  S: string;
begin
  Rows := FRows - FStatusRows;
  if Rows < 1 then Rows := 1;
  if FNeedsClear then
    begin
      ClearScreen;
      FNeedsClear := False;
    end;

  Pos := 0;
  SetLength(FBuf, 4096);
  for Row := 0 to Rows - 1 do
    begin
      BufAppend(FBuf, Pos, ESC + '[');
      BufAppendInt(FBuf, Pos, Row + 1);
      BufAppend(FBuf, Pos, ';1H');
      for X := 0 to FCols - 1 do
        begin
          Top := RGBAFromVec(Renderer.ColorAt(X, Row * 2));
          Bottom := RGBAFromVec(Renderer.ColorAt(X, Row * 2 + 1));
          if FColorMode = cmMono then
            begin
              Lum := (Top.R + Top.G + Top.B + Bottom.R + Bottom.G + Bottom.B) div 6;
              Idx := ClampI(Lum * 9 div 255, 0, 9);
              BufAppendChar(FBuf, Pos, Ramp[Idx]);
            end
          else
            begin
              AppendColor(FBuf, Pos, FColorMode, Top, Bottom);
              BufAppend(FBuf, Pos, HalfBlock);
            end;
        end;
    end;
  BufAppend(FBuf, Pos, ESC + '[0m');

  if FOverlay.Count > 0 then
    for Row := 0 to FOverlay.Count - 1 do
      begin
        if Row >= Rows then Break;
        BufAppend(FBuf, Pos, ESC + '[');
        BufAppendInt(FBuf, Pos, Row + 1);
        BufAppend(FBuf, Pos, ';1H');
        S := FOverlay[Row];
        if Length(S) > FCols then S := Copy(S, 1, FCols);
        while Length(S) < FCols do S := S + ' ';
        BufAppend(FBuf, Pos, S);
      end;
  BufAppend(FBuf, Pos, ESC + '[0m');

  if FStatusRows > 0 then
    begin
      BufAppend(FBuf, Pos, ESC + '[');
      BufAppendInt(FBuf, Pos, Rows + 1);
      BufAppend(FBuf, Pos, ';1H');
      S := FStatus;
      if Length(S) > FCols then S := Copy(S, 1, FCols);
      while Length(S) < FCols do S := S + ' ';
      BufAppend(FBuf, Pos, S);
      BufAppend(FBuf, Pos, ESC + '[0m');
    end;

  SetLength(FBuf, Pos);
  WriteRaw(FBuf);
end;

{ ================================================================== input == }

procedure TConsoleDisplay.QueueEvent(const E: TInputEvent);
var
  Slot: LongInt;
begin
  if FQueueCount >= Length(FQueue) then Exit;
  Slot := (FQueueHead + FQueueCount) mod Length(FQueue);
  FQueue[Slot] := E;
  Inc(FQueueCount);
end;

procedure TConsoleDisplay.PushKey(K: TKey; Ch: AnsiChar);
var
  E: TInputEvent;
begin
  FillChar(E, SizeOf(E), 0);
  E.Kind := ieKeyDown;
  E.Key := K;
  E.Ch := Ch;
  QueueEvent(E);
end;

procedure TConsoleDisplay.PushQuit;
var
  E: TInputEvent;
begin
  FillChar(E, SizeOf(E), 0);
  E.Kind := ieQuit;
  QueueEvent(E);
end;

function TConsoleDisplay.CanRead(Ms: LongInt): Boolean;
var
  FDS: TFDSet;
  TV: TTimeVal;
begin
  fpfdZero(FDS);
  fpfdSet(FDS, 0);
  TV.tv_sec := Ms div 1000;
  TV.tv_usec := (Ms mod 1000) * 1000;
  Result := fpSelect(1, @FDS, nil, nil, @TV) > 0;
end;

function TConsoleDisplay.ReadByteTimeout(out B: Byte; Ms: LongInt): Boolean;
var
  N: TSize;
begin
  Result := False;
  B := 0;
  if not CanRead(Ms) then Exit;
  N := fpRead(0, @B, 1);
  Result := N = 1;
end;

procedure TConsoleDisplay.HandleEscape;
var
  B, B2, B3: Byte;
begin
  if not ReadByteTimeout(B, 30) then
    begin
      PushKey(kEscape, #0);
      Exit;
    end;
  if B = Ord('O') then
    begin
      if ReadByteTimeout(B, 30) then
        case Chr(B) of
          'A': PushKey(kUp, #0);
          'B': PushKey(kDown, #0);
          'C': PushKey(kRight, #0);
          'D': PushKey(kLeft, #0);
          'H': PushKey(kHome, #0);
          'F': PushKey(kEnd, #0);
          'P': PushKey(kF1, #0);
          'Q': PushKey(kF2, #0);
          'R': PushKey(kF3, #0);
          'S': PushKey(kF4, #0);
        end;
      Exit;
    end;
  if B <> Ord('[') then
    begin
      PushKey(kEscape, #0);
      Exit;
    end;
  if not ReadByteTimeout(B2, 30) then
    begin
      PushKey(kEscape, #0);
      Exit;
    end;
  case Chr(B2) of
    'A': PushKey(kUp, #0);
    'B': PushKey(kDown, #0);
    'C': PushKey(kRight, #0);
    'D': PushKey(kLeft, #0);
    'H': PushKey(kHome, #0);
    'F': PushKey(kEnd, #0);
    'Z': PushKey(kTab, #0);
    '1', '2', '3', '4', '5', '6':
      begin
        if ReadByteTimeout(B3, 30) and (Chr(B3) = '~') then
          case Chr(B2) of
            '1', '7': PushKey(kHome, #0);
            '2': PushKey(kNone, #0);
            '3': PushKey(kDelete, #0);
            '4', '8': PushKey(kEnd, #0);
            '5': PushKey(kPageUp, #0);
            '6': PushKey(kPageDown, #0);
          end;
      end;
  end;
end;

procedure TConsoleDisplay.HandleBytes(const Buf: array of Byte; Count: LongInt);
{ Every character is one key press.  There is no key release in a terminal:
  the input layer keeps a press held for HoldTime seconds. }
var
  I: LongInt;
  C: Byte;
begin
  I := 0;
  while I < Count do
    begin
      C := Buf[I];
      case C of
        3, 4:
          begin
            PushQuit;
            Exit;
          end;
        27:
          begin
            HandleEscape;
            Exit;                     // the escape reader consumed what it needed
          end;
        9: PushKey(kTab, #0);
        10, 13: PushKey(kEnter, #0);
        8, 127: PushKey(kBackspace, #0);
        32: PushKey(kSpace, ' ');
        43, 61: PushKey(kPlus, AnsiChar(C));
        45, 95: PushKey(kMinus, AnsiChar(C));
        else
          if (C >= 33) and (C < 127) then
            PushKey(kNone, AnsiChar(C));
      end;
      Inc(I);
    end;
end;

function TConsoleDisplay.PollEvent(out E: TInputEvent): Boolean;
var
  Buf: array[0..255] of Byte;
  N: TSize;
  Slot: LongInt;
begin
  Result := False;
  FillChar(E, SizeOf(E), 0);

  if not FRawMode then Exit;

  Inc(FPollCounter);
  if (FPollCounter mod 60) = 0 then
    begin
      ResizeToTerminal;
      if FNeedsClear then
        begin
          E.Kind := ieResize;
          E.Width := Width;
          E.Height := Height;
          Result := True;
          Exit;
        end;
    end;

  if CanRead(0) then
    begin
      N := fpRead(0, @Buf[0], SizeOf(Buf));
      if N > 0 then
        HandleBytes(Buf, LongInt(N));
    end;

  if FQueueCount = 0 then Exit;
  Slot := FQueueHead;
  E := FQueue[Slot];
  FQueueHead := (FQueueHead + 1) mod Length(FQueue);
  Dec(FQueueCount);
  Result := True;
end;

end.
