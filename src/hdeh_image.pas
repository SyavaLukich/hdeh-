{ ============================================================================
  hdeh-image - RGBA images, texture sampling, file IO and procedural textures.

  The pixel layout is R,G,B,A in memory (that is exactly the layout used by
  SDL_PIXELFORMAT_ABGR8888, so an image can be handed straight to SDL), and
  it is also the layout of the PPM/PNG files written by SavePPM/SavePNG.

  Texture space is the same as in OpenGL: u goes right, v goes *up*, so
  v = 0 is the last row of the image.  Sampling functions take u,v in [0,1]
  and honour the images wrap mode.

  PNG files are written with stored (uncompressed) deflate blocks - no
  external zlib/paszlib dependency, and the files are readable by every
  program that reads PNG.  Compressed output is not worth an extra library
  dependency here, screenshots are small enough.
  ============================================================================ }
unit hdeh_image;
{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, hdeh_math;

type
  TRGBA = packed record
    R, G, B, A: Byte;
  end;
  PRGBA = ^TRGBA;
  TRGBABuffer = array of TRGBA;

  TWrapMode = (wmRepeat, wmClamp);
  TSampler = (smpNearest, smpBilinear);

  TImage = class
  private
    FWidth, FHeight: LongInt;
    FData: TRGBABuffer;
    FWrap: TWrapMode;
    function GetPixel(X, Y: LongInt): TRGBA;
    procedure SetPixel(X, Y: LongInt; const Value: TRGBA);
  public
    constructor Create(AWidth, AHeight: LongInt);
    constructor CreateFromFile(const FileName: string);
    destructor Destroy; override;

    procedure Fill(const C: TRGBA);
    procedure FillLinear(const C: TVec3);          // linear colour -> sRGB bytes
    procedure FlipVertical;

    property Width: LongInt read FWidth;
    property Height: LongInt read FHeight;
    property Wrap: TWrapMode read FWrap write FWrap;
    property Pixels[X, Y: LongInt]: TRGBA read GetPixel write SetPixel; default;
    property RawData: TRGBABuffer read FData;

    function Texel(TX, TY: LongInt): TRGBA;                       // integer, wrapped
    function SampleNearest(U, V: Single): TRGBA;
    function SampleBilinear(U, V: Single): TRGBA;
    function Sample(U, V: Single; Mode: TSampler): TRGBA;
    function SampleNearestLinear(U, V: Single): TVec3;            // linear colour
    function SampleBilinearLinear(U, V: Single): TVec3;

    procedure SavePPM(const FileName: string);
    procedure SavePNG(const FileName: string);
    procedure LoadPPM(const FileName: string);
    procedure LoadBMP(const FileName: string);
    procedure LoadFromFile(const FileName: string);
    procedure CopyFrom(Src: TImage);
    procedure DrawImage(const Src: TImage; X, Y: LongInt);        // simple blit, alpha ignored
  end;

{ -------------------------------------------------------------- colours --- }
function RGBA(R, G, B: Byte; A: Byte = 255): TRGBA; overload;
function RGBAc(R, G, B: Integer; A: Integer = 255): TRGBA; overload;
function Gray(Value: Byte; A: Byte = 255): TRGBA;
function ColToVec(const C: TRGBA): TVec3;          // sRGB byte -> linear float
function RGBAFromVec(const C: TVec3; A: Single = 1): TRGBA;
function SRGBToLinear8(V: Byte): Single;
function LinearToSRGB8(V: Single): Byte;
function AlphaOf(const C: TRGBA): Single;

{ ------------------------------------------------------ image functions --- }
function ImageLoad(const FileName: string): TImage;
procedure ImageSave(const Img: TImage; const FileName: string);
function ImageClone(const Src: TImage): TImage;

{ -------------------------------------------------- procedural textures --- }
function TexFlat(Size: LongInt; const C: TRGBA): TImage;
function TexChecker(Size, Squares: LongInt; const C1, C2: TRGBA): TImage;
function TexGrid(Size, Cells, LineWidth: LongInt; const Base, Line: TVec3;
                 NoiseAmount: Single; Seed: LongWord): TImage;
function TexNoiseTexture(Size: LongInt; Seed: LongWord; const C1, C2: TRGBA;
                         Scale, Contrast: Single): TImage;
function TexNormalMapFromHeight(Height: TImage; Strength: Single): TImage;
function TexTiles(Size, Cells: LongInt; const TileColor, GroutColor: TVec3;
                  Seed: LongWord): TImage;

implementation

var
  SRGBTable: array[0..255] of Single;
  LinearTable: array[0..1023] of Byte;
  TblI: LongInt;

function RGBA(R, G, B: Byte; A: Byte): TRGBA;
begin
  Result.R := R;
  Result.G := G;
  Result.B := B;
  Result.A := A;
end;

function RGBAc(R, G, B: Integer; A: Integer): TRGBA;
begin
  Result.R := ClampI(R, 0, 255);
  Result.G := ClampI(G, 0, 255);
  Result.B := ClampI(B, 0, 255);
  Result.A := ClampI(A, 0, 255);
end;

function Gray(Value: Byte; A: Byte): TRGBA;
begin
  Result.R := Value;
  Result.G := Value;
  Result.B := Value;
  Result.A := A;
end;

function SRGBToLinear8(V: Byte): Single;
begin
  Result := SRGBTable[V];
end;

function LinearToSRGB8(V: Single): Byte;
var
  I: LongInt;
begin
  I := Trunc(V * 1023);
  if I < 0 then I := 0
  else if I > 1023 then I := 1023;
  Result := LinearTable[I];
end;

function ColToVec(const C: TRGBA): TVec3;
begin
  Result.X := SRGBTable[C.R];
  Result.Y := SRGBTable[C.G];
  Result.Z := SRGBTable[C.B];
end;

function RGBAFromVec(const C: TVec3; A: Single): TRGBA;
begin
  Result.R := LinearToSRGB8(C.X);
  Result.G := LinearToSRGB8(C.Y);
  Result.B := LinearToSRGB8(C.Z);
  Result.A := LinearToSRGB8(A);
end;

function AlphaOf(const C: TRGBA): Single;
begin
  Result := C.A * (1 / 255);
end;

{ ================================================================= image === }

constructor TImage.Create(AWidth, AHeight: LongInt);
begin
  inherited Create;
  FWidth := AWidth;
  FHeight := AHeight;
  FWrap := wmRepeat;
  if (FWidth < 1) or (FHeight < 1) then
    raise Exception.CreateFmt('TImage.Create: bad size %dx%d', [AWidth, AHeight]);
  SetLength(FData, FWidth * FHeight);
end;

constructor TImage.CreateFromFile(const FileName: string);
begin
  Create(1, 1);
  LoadFromFile(FileName);
end;

destructor TImage.Destroy;
begin
  SetLength(FData, 0);
  inherited Destroy;
end;

function TImage.GetPixel(X, Y: LongInt): TRGBA;
begin
  Result := FData[Y * FWidth + X];
end;

procedure TImage.SetPixel(X, Y: LongInt; const Value: TRGBA);
begin
  FData[Y * FWidth + X] := Value;
end;

procedure TImage.Fill(const C: TRGBA);
var
  I: LongInt;
begin
  for I := 0 to High(FData) do
    FData[I] := C;
end;

procedure TImage.FillLinear(const C: TVec3);
begin
  Fill(RGBAFromVec(C));
end;

procedure TImage.FlipVertical;
var
  X, Y: LongInt;
  T: TRGBA;
begin
  for Y := 0 to (FHeight div 2) - 1 do
    for X := 0 to FWidth - 1 do
      begin
        T := FData[Y * FWidth + X];
        FData[Y * FWidth + X] := FData[(FHeight - 1 - Y) * FWidth + X];
        FData[(FHeight - 1 - Y) * FWidth + X] := T;
      end;
end;

function WrapInt(X, N: LongInt): LongInt;
begin
  Result := X mod N;
  if Result < 0 then Result := Result + N;
end;

function TImage.Texel(TX, TY: LongInt): TRGBA;
begin
  if FWrap = wmRepeat then
    Result := FData[WrapInt(TY, FHeight) * FWidth + WrapInt(TX, FWidth)]
  else
    begin
      TX := ClampI(TX, 0, FWidth - 1);
      TY := ClampI(TY, 0, FHeight - 1);
      Result := FData[TY * FWidth + TX];
    end;
end;

function TImage.SampleNearest(U, V: Single): TRGBA;
var
  X, Y: LongInt;
begin
  X := Floor(U * FWidth);
  Y := Floor((1 - V) * FHeight);
  Result := Texel(X, Y);
end;

function TImage.SampleBilinear(U, V: Single): TRGBA;
var
  X, Y, X0, Y0: LongInt;
  FX, FY: Single;
  C00, C10, C01, C11: TRGBA;
  R, G, B, A: Single;
begin
  X := Floor(U * FWidth - 0.5);
  Y := Floor((1 - V) * FHeight - 0.5);
  FX := U * FWidth - 0.5 - X;
  FY := (1 - V) * FHeight - 0.5 - Y;
  X0 := X + 1;
  Y0 := Y + 1;

  C00 := Texel(X, Y);
  C10 := Texel(X0, Y);
  C01 := Texel(X, Y0);
  C11 := Texel(X0, Y0);

  R := LerpS(LerpS(C00.R, C10.R, FX), LerpS(C01.R, C11.R, FX), FY);
  G := LerpS(LerpS(C00.G, C10.G, FX), LerpS(C01.G, C11.G, FX), FY);
  B := LerpS(LerpS(C00.B, C10.B, FX), LerpS(C01.B, C11.B, FX), FY);
  A := LerpS(LerpS(C00.A, C10.A, FX), LerpS(C01.A, C11.A, FX), FY);

  Result.R := ClampI(Round(R), 0, 255);
  Result.G := ClampI(Round(G), 0, 255);
  Result.B := ClampI(Round(B), 0, 255);
  Result.A := ClampI(Round(A), 0, 255);
end;

function TImage.Sample(U, V: Single; Mode: TSampler): TRGBA;
begin
  if Mode = smpBilinear then
    Result := SampleBilinear(U, V)
  else
    Result := SampleNearest(U, V);
end;

function TImage.SampleNearestLinear(U, V: Single): TVec3;
begin
  Result := ColToVec(SampleNearest(U, V));
end;

function TImage.SampleBilinearLinear(U, V: Single): TVec3;
begin
  Result := ColToVec(SampleBilinear(U, V));
end;

procedure TImage.CopyFrom(Src: TImage);
var
  Y, X: LongInt;
begin
  if (Src.Width <> FWidth) or (Src.Height <> FHeight) then
    begin
      FWidth := Src.Width;
      FHeight := Src.Height;
      SetLength(FData, FWidth * FHeight);
    end;
  for Y := 0 to FHeight - 1 do
    for X := 0 to FWidth - 1 do
      FData[Y * FWidth + X] := Src[X, Y];
end;

procedure TImage.DrawImage(const Src: TImage; X, Y: LongInt);
var
  SX, SY, DX, DY: LongInt;
begin
  for SY := 0 to Src.Height - 1 do
    begin
      DY := Y + SY;
      if (DY < 0) or (DY >= FHeight) then Continue;
      for SX := 0 to Src.Width - 1 do
        begin
          DX := X + SX;
          if (DX < 0) or (DX >= FWidth) then Continue;
          FData[DY * FWidth + DX] := Src[SX, SY];
        end;
    end;
end;

{ ============================================================= raw file IO = }

function ReadU8(S: TStream): Byte;
begin
  S.ReadBuffer(Result, 1);
end;

function ReadU16LE(S: TStream): Word;
var
  B: array[0..1] of Byte;
begin
  S.ReadBuffer(B, 2);
  Result := Word(B[0]) or (Word(B[1]) shl 8);
end;

function ReadU32LE(S: TStream): LongWord;
var
  B: array[0..3] of Byte;
begin
  S.ReadBuffer(B, 4);
  Result := LongWord(B[0]) or (LongWord(B[1]) shl 8) or
            (LongWord(B[2]) shl 16) or (LongWord(B[3]) shl 24);
end;

procedure WriteU16LE(S: TStream; V: Word);
var
  B: array[0..1] of Byte;
begin
  B[0] := V and $FF;
  B[1] := (V shr 8) and $FF;
  S.WriteBuffer(B, 2);
end;

procedure WriteU32LE(S: TStream; V: LongWord);
var
  B: array[0..3] of Byte;
begin
  B[0] := V and $FF;
  B[1] := (V shr 8) and $FF;
  B[2] := (V shr 16) and $FF;
  B[3] := (V shr 24) and $FF;
  S.WriteBuffer(B, 4);
end;

procedure WriteU32BE(S: TStream; V: LongWord);
var
  B: array[0..3] of Byte;
begin
  B[0] := (V shr 24) and $FF;
  B[1] := (V shr 16) and $FF;
  B[2] := (V shr 8) and $FF;
  B[3] := V and $FF;
  S.WriteBuffer(B, 4);
end;

procedure SkipWhitespaceAndComments(S: TStream; var Ch: Byte);
{ PPM header tokens; '#' starts a comment that runs to the end of the line }
begin
  while Ch in [0, 9, 10, 13, 32] do Ch := ReadU8(S);
  while Ch = Ord('#') do
    begin
      repeat
        Ch := ReadU8(S);
      until (Ch = 10) or (S.Position >= S.Size);
      while Ch in [0, 9, 10, 13, 32] do Ch := ReadU8(S);
    end;
end;

procedure RequireToken(S: TStream; var Ch: Byte; Expected: Byte; const What: string);
begin
  if Ch <> Expected then
    raise Exception.CreateFmt('%s: expected "%s"', [What, Chr(Expected)]);
  Ch := ReadU8(S);
end;

function ReadPPMInt(S: TStream; var Ch: Byte; const What: string): LongInt;
var
  V: LongInt;
begin
  SkipWhitespaceAndComments(S, Ch);
  V := 0;
  if not (Ch in [Ord('0')..Ord('9')]) then
    raise Exception.CreateFmt('%s: expected a number', [What]);
  while Ch in [Ord('0')..Ord('9')] do
    begin
      V := V * 10 + (Ch - Ord('0'));
      Ch := ReadU8(S);
    end;
  Result := V;
end;

procedure TImage.SavePPM(const FileName: string);
{ binary P6, no compression - dead simple and understood by every image tool }
var
  S: TFileStream;
  Header: AnsiString;
  X, Y: LongInt;
  Row: array of Byte;
begin
  SetLength(Row, FWidth * 3);
  S := TFileStream.Create(FileName, fmCreate);
  try
    Header := Format('P6'#10'# hdeh 3D engine'#10'%d %d'#10'255'#10, [FWidth, FHeight]);
    S.WriteBuffer(Header[1], Length(Header));
    for Y := 0 to FHeight - 1 do
      begin
        for X := 0 to FWidth - 1 do
          begin
            Row[X * 3 + 0] := FData[Y * FWidth + X].R;
            Row[X * 3 + 1] := FData[Y * FWidth + X].G;
            Row[X * 3 + 2] := FData[Y * FWidth + X].B;
          end;
        S.WriteBuffer(Row[0], Length(Row));
      end;
  finally
    S.Free;
  end;
end;

{ ------------------------------------------------------------ PNG output --- }

var
  CRCTable: array[0..255] of LongWord;
  CRCTableReady: Boolean = False;

procedure InitCRCTable;
var
  I, J: LongInt;
  C: LongWord;
begin
  if CRCTableReady then Exit;
  for I := 0 to 255 do
    begin
      C := LongWord(I);
      for J := 0 to 7 do
        if (C and 1) <> 0 then
          C := $EDB88320 xor (C shr 1)
        else
          C := C shr 1;
      CRCTable[I] := C;
    end;
  CRCTableReady := True;
end;

function CRC32Of(const Data: Pointer; Len: LongInt): LongWord;
var
  P: PByte;
  I: LongInt;
begin
  InitCRCTable;
  Result := $FFFFFFFF;
  P := PByte(Data);
  for I := 0 to Len - 1 do
    begin
      Result := CRCTable[(Result xor P^) and $FF] xor (Result shr 8);
      Inc(P);
    end;
  Result := Result xor $FFFFFFFF;
end;

function Adler32Of(const Data: Pointer; Len: LongInt): LongWord;
const
  MOD_ADLER = 65521;
var
  P: PByte;
  I: LongInt;
  A, B: LongWord;
begin
  A := 1;
  B := 0;
  P := PByte(Data);
  for I := 0 to Len - 1 do
    begin
      A := (A + P^) mod MOD_ADLER;
      B := (B + A) mod MOD_ADLER;
      Inc(P);
    end;
  Result := (B shl 16) or A;
end;

procedure WritePNGChunk(S: TStream; const Kind: string; const Data; Len: LongInt);
var
  CRC: LongWord;
  Buf: Pointer;
  Total: LongInt;
begin
  WriteU32BE(S, LongWord(Len));
  S.WriteBuffer(Kind[1], 4);
  if Len > 0 then
    S.WriteBuffer(Data, Len);
  Total := 4 + Len;
  GetMem(Buf, Total);
  try
    Move(Kind[1], Buf^, 4);
    if Len > 0 then
      Move(Data, Pointer(PByte(Buf) + 4)^, Len);
    CRC := CRC32Of(Buf, Total);
  finally
    FreeMem(Buf);
  end;
  WriteU32BE(S, CRC);
end;

procedure TImage.SavePNG(const FileName: string);
var
  S: TFileStream;
  Raw: PByte;
  RawLen: LongInt;
  Y, X: LongInt;
  Idat: PByte;
  IdatLen: LongInt;
  Offset, PosOut: LongInt;
  BlockLen: LongInt;
  Hdr: array[0..12] of Byte;
  Sig: array[0..7] of Byte;
  ZlibHdr: array[0..1] of Byte;
  P: PByte;
  Ad: LongWord;
begin
  InitCRCTable;

  RawLen := (FWidth * 4 + 1) * FHeight;
  GetMem(Raw, RawLen);
  try
    P := Raw;
    for Y := 0 to FHeight - 1 do
      begin
        P^ := 0;                    // filter type: none
        Inc(P);
        for X := 0 to FWidth - 1 do
          begin
            P^ := FData[Y * FWidth + X].R; Inc(P);
            P^ := FData[Y * FWidth + X].G; Inc(P);
            P^ := FData[Y * FWidth + X].B; Inc(P);
            P^ := FData[Y * FWidth + X].A; Inc(P);
          end;
      end;

    // zlib stream: 2 byte header + stored deflate blocks + adler32
    IdatLen := 2 + RawLen + (RawLen div 65535 + 1) * 5 + 4;
    GetMem(Idat, IdatLen);
    try
      PosOut := 0;
      Idat[PosOut] := $78; Inc(PosOut);      // CMF: deflate, 32k window
      Idat[PosOut] := $01; Inc(PosOut);      // FLG: check bits, fastest
      Offset := 0;
      repeat
        if RawLen - Offset > 65535 then
          BlockLen := 65535
        else
          BlockLen := RawLen - Offset;
        if Offset + BlockLen >= RawLen then
          Idat[PosOut] := 1                    // final block
        else
          Idat[PosOut] := 0;
        Inc(PosOut);
        Idat[PosOut] := BlockLen and $FF; Inc(PosOut);
        Idat[PosOut] := (BlockLen shr 8) and $FF; Inc(PosOut);
        Idat[PosOut] := (not BlockLen) and $FF; Inc(PosOut);
        Idat[PosOut] := ((not BlockLen) shr 8) and $FF; Inc(PosOut);
        Move(Raw[Offset], Idat[PosOut], BlockLen);
        Inc(PosOut, BlockLen);
        Inc(Offset, BlockLen);
      until Offset >= RawLen;
      Ad := Adler32Of(Raw, RawLen);
      Idat[PosOut] := (Ad shr 24) and $FF; Inc(PosOut);
      Idat[PosOut] := (Ad shr 16) and $FF; Inc(PosOut);
      Idat[PosOut] := (Ad shr 8) and $FF; Inc(PosOut);
      Idat[PosOut] := Ad and $FF; Inc(PosOut);
      IdatLen := PosOut;

      Sig[0] := $89; Sig[1] := Ord('P'); Sig[2] := Ord('N'); Sig[3] := Ord('G');
      Sig[4] := 13; Sig[5] := 10; Sig[6] := 26; Sig[7] := 10;

      Hdr[0] := (FWidth shr 24) and $FF;
      Hdr[1] := (FWidth shr 16) and $FF;
      Hdr[2] := (FWidth shr 8) and $FF;
      Hdr[3] := FWidth and $FF;
      Hdr[4] := (FHeight shr 24) and $FF;
      Hdr[5] := (FHeight shr 16) and $FF;
      Hdr[6] := (FHeight shr 8) and $FF;
      Hdr[7] := FHeight and $FF;
      Hdr[8] := 8;      // bit depth
      Hdr[9] := 6;      // colour type: truecolour + alpha
      Hdr[10] := 0;     // compression
      Hdr[11] := 0;     // filter
      Hdr[12] := 0;     // interlace

      S := TFileStream.Create(FileName, fmCreate);
      try
        S.WriteBuffer(Sig, 8);
        WritePNGChunk(S, 'IHDR', Hdr, 13);
        WritePNGChunk(S, 'IDAT', Idat^, IdatLen);
        WritePNGChunk(S, 'IEND', Sig, 0);
      finally
        S.Free;
      end;
    finally
      FreeMem(Idat);
    end;
  finally
    FreeMem(Raw);
  end;
end;

{ -------------------------------------------------------------- PPM input --- }

procedure TImage.LoadPPM(const FileName: string);
var
  S: TFileStream;
  Ch: Byte;
  MaxVal, W, H: LongInt;
  X, Y: LongInt;
  Row: array of Byte;
begin
  S := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    Ch := ReadU8(S);
    RequireToken(S, Ch, Ord('P'), 'PPM');
    Ch := ReadU8(S);
    RequireToken(S, Ch, Ord('6'), 'PPM (only binary P6 is supported)');
    W := ReadPPMInt(S, Ch, 'PPM width');
    H := ReadPPMInt(S, Ch, 'PPM height');
    MaxVal := ReadPPMInt(S, Ch, 'PPM max value');
    if MaxVal > 255 then
      raise Exception.Create('PPM: 16 bit samples are not supported');
    if (W < 1) or (H < 1) then
      raise Exception.Create('PPM: bad dimensions');
    // exactly one whitespace character follows the maxval
    FWidth := W;
    FHeight := H;
    SetLength(FData, W * H);
    SetLength(Row, W * 3);
    for Y := 0 to H - 1 do
      begin
        S.ReadBuffer(Row[0], Length(Row));
        for X := 0 to W - 1 do
          FData[Y * W + X] := RGBA(Row[X * 3], Row[X * 3 + 1], Row[X * 3 + 2], 255);
      end;
  finally
    S.Free;
  end;
end;

{ -------------------------------------------------------------- BMP input --- }

procedure TImage.LoadBMP(const FileName: string);
var
  S: TFileStream;
  Magic: array[0..1] of Byte;
  DataOffset, HeaderSize: LongWord;
  W, H: LongInt;
  Bpp, Compression: Word;
  RowStride, X, Y, SrcY: LongInt;
  Row: array of Byte;
  C: TRGBA;
begin
  S := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    S.ReadBuffer(Magic, 2);
    if (Magic[0] <> Ord('B')) or (Magic[1] <> Ord('M')) then
      raise Exception.Create('BMP: bad magic');
    S.Position := 10;
    DataOffset := ReadU32LE(S);
    HeaderSize := ReadU32LE(S);
    if HeaderSize < 40 then
      raise Exception.Create('BMP: unsupported DIB header');
    W := LongInt(ReadU32LE(S));
    H := LongInt(ReadU32LE(S));
    S.Position := 28;
    Bpp := ReadU16LE(S);
    Compression := ReadU16LE(S);
    if Compression <> 0 then
      raise Exception.Create('BMP: compressed bitmaps are not supported');
    if not ((Bpp = 24) or (Bpp = 32)) then
      raise Exception.CreateFmt('BMP: %d bit pixels are not supported', [Bpp]);
    if W <= 0 then
      raise Exception.Create('BMP: bad width');

    FWidth := W;
    FHeight := Abs(H);
    SetLength(FData, FWidth * FHeight);
    RowStride := ((Bpp * FWidth + 31) div 32) * 4;
    SetLength(Row, RowStride);
    S.Position := DataOffset;

    for Y := 0 to FHeight - 1 do
      begin
        S.ReadBuffer(Row[0], RowStride);
        if H > 0 then SrcY := FHeight - 1 - Y else SrcY := Y;   // bottom-up by default
        for X := 0 to FWidth - 1 do
          begin
            C.B := Row[X * (Bpp div 8) + 0];
            C.G := Row[X * (Bpp div 8) + 1];
            C.R := Row[X * (Bpp div 8) + 2];
            if Bpp = 32 then C.A := Row[X * 4 + 3] else C.A := 255;
            FData[SrcY * FWidth + X] := C;
          end;
      end;
  finally
    S.Free;
  end;
end;

procedure TImage.LoadFromFile(const FileName: string);
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(FileName));
  if Ext = '.ppm' then
    LoadPPM(FileName)
  else if Ext = '.bmp' then
    LoadBMP(FileName)
  else
    raise Exception.CreateFmt('image format "%s" is not supported (use .ppm or .bmp)', [Ext]);
end;

function ImageLoad(const FileName: string): TImage;
begin
  Result := TImage.CreateFromFile(FileName);
end;

procedure ImageSave(const Img: TImage; const FileName: string);
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(FileName));
  if Ext = '.png' then
    Img.SavePNG(FileName)
  else if Ext = '.ppm' then
    Img.SavePPM(FileName)
  else
    raise Exception.CreateFmt('image format "%s" is not supported (use .ppm or .png)', [Ext]);
end;

function ImageClone(const Src: TImage): TImage;
begin
  Result := TImage.Create(Src.Width, Src.Height);
  Result.Wrap := Src.Wrap;
  Result.CopyFrom(Src);
end;

{ ================================================== procedural textures ==== }

function TexFlat(Size: LongInt; const C: TRGBA): TImage;
begin
  Result := TImage.Create(Size, Size);
  Result.Fill(C);
end;

function TexChecker(Size, Squares: LongInt; const C1, C2: TRGBA): TImage;
var
  X, Y, Cell: LongInt;
begin
  Result := TImage.Create(Size, Size);
  if Squares < 1 then Squares := 1;
  for Y := 0 to Size - 1 do
    for X := 0 to Size - 1 do
      begin
        Cell := (X * Squares div Size) + (Y * Squares div Size);
        if Odd(Cell) then
          Result[X, Y] := C1
        else
          Result[X, Y] := C2;
      end;
end;

function TexGrid(Size, Cells, LineWidth: LongInt; const Base, Line: TVec3;
                 NoiseAmount: Single; Seed: LongWord): TImage;
{ The classic reference floor: a square grid of cells with darker lines in
  between, a bit of fbm noise mixed into the base colour and a subtle
  gradient.  Cells/LineWidth are given in texels. }
var
  X, Y: LongInt;
  Cell, LX, LY, L: LongInt;
  N: Single;
  C, LineCol: TVec3;
begin
  Result := TImage.Create(Size, Size);
  if Cells < 1 then Cells := 1;
  Cell := Size div Cells;
  if Cell < 1 then Cell := 1;
  LineCol := Line;
  for Y := 0 to Size - 1 do
    for X := 0 to Size - 1 do
      begin
        N := FBM2D(X / 24, Y / 24, 4, Seed) - 0.5;
        C := Base * (1 + N * NoiseAmount);
        LX := X mod Cell;
        LY := Y mod Cell;
        L := LineWidth;
        if (LX < L) or (LY < L) or (LX >= Cell - L) or (LY >= Cell - L) then
          begin
            // soft edges of the line
            C := LineCol;
            if (LX < L) and (LX > 0) then C := C * 0.7;
          end;
        Result[X, Y] := RGBAFromVec(C);
      end;
end;

function TexTiles(Size, Cells: LongInt; const TileColor, GroutColor: TVec3;
                  Seed: LongWord): TImage;
var
  X, Y, Cell, G, LX, LY: LongInt;
  N: Single;
  C: TVec3;
  Tint: Single;
begin
  Result := TImage.Create(Size, Size);
  if Cells < 1 then Cells := 1;
  Cell := Size div Cells;
  if Cell < 1 then Cell := 1;
  G := Cell div 10;
  if G < 1 then G := 1;
  for Y := 0 to Size - 1 do
    for X := 0 to Size - 1 do
      begin
        LX := X mod Cell;
        LY := Y mod Cell;
        if (LX < G) or (LY < G) then
          C := GroutColor * (0.9 + 0.2 * Noise2D(X / 3, Y / 3, Seed))
        else
          begin
            // per tile brightness variation
            Tint := 0.85 + 0.3 * Noise2D((X div Cell) * 1.7, (Y div Cell) * 1.7, Seed + 5);
            N := 0.92 + 0.16 * FBM2D(X / 16, Y / 16, 4, Seed + 11);
            C := TileColor * (Tint * N);
            // darken towards the grout for a fake bevel
            if (LX < G * 3) or (LY < G * 3) then C := C * 0.94;
            if (LX > Cell - G * 3) or (LY > Cell - G * 3) then C := C * 0.94;
          end;
        Result[X, Y] := RGBAFromVec(C);
      end;
end;

function TexNoiseTexture(Size: LongInt; Seed: LongWord; const C1, C2: TRGBA;
                         Scale, Contrast: Single): TImage;
var
  X, Y: LongInt;
  N: Single;
  A, B: TVec3;
begin
  Result := TImage.Create(Size, Size);
  A := ColToVec(C1);
  B := ColToVec(C2);
  for Y := 0 to Size - 1 do
    for X := 0 to Size - 1 do
      begin
        N := FBM2D(X * Scale / Size, Y * Scale / Size, 5, Seed);
        N := Saturate((N - 0.5) * Contrast + 0.5);
        Result[X, Y] := RGBAFromVec(Vec3Lerp(A, B, N));
      end;
end;

function TexNormalMapFromHeight(Height: TImage; Strength: Single): TImage;
var
  X, Y: LongInt;
  Hl, Hr, Hd, Hu: Single;
  N: TVec3;
begin
  Result := TImage.Create(Height.Width, Height.Height);
  for Y := 0 to Height.Height - 1 do
    for X := 0 to Height.Width - 1 do
      begin
        Hl := SRGBToLinear8(Height.Texel(X - 1, Y).R);
        Hr := SRGBToLinear8(Height.Texel(X + 1, Y).R);
        Hd := SRGBToLinear8(Height.Texel(X, Y - 1).R);
        Hu := SRGBToLinear8(Height.Texel(X, Y + 1).R);
        N := Vec3Normalize(Vec3(-(Hr - Hl) * Strength, -(Hu - Hd) * Strength, 1));
        // store as 0..1 vector, R = x, G = y, B = z
        Result[X, Y] := RGBA(ClampI(Round((N.X * 0.5 + 0.5) * 255), 0, 255),
                             ClampI(Round((N.Y * 0.5 + 0.5) * 255), 0, 255),
                             ClampI(Round((N.Z * 0.5 + 0.5) * 255), 0, 255), 255);
      end;
end;

initialization
  { sRGB <-> linear conversion tables.  The engine shades in linear space
    and converts only when a colour is read from a texture or written into
    the framebuffer of a display. }
  for TblI := 0 to 255 do
    SRGBTable[TblI] := Power(TblI / 255, 2.2);
  for TblI := 0 to 1023 do
    LinearTable[TblI] := Round(255 * Power(TblI / 1023, 1 / 2.2));
end.
