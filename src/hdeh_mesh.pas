{ ============================================================================
  hdeh-mesh - triangle meshes and primitive builders.

  A mesh is a plain indexed triangle list:

      Positions[i]  - vertex position (model space)
      Normals[i]    - vertex normal (unit length, model space)
      UVs[i]        - texture coordinates
      Indices[...]  - 3 entries per triangle

  The arrays are public on purpose: the rasterizer walks them every frame
  and going through properties would cost a reference count per access.

  Texture coordinates are either stored per vertex ("direct" mapping) or
  computed from the vertex position by projecting it onto one of the three
  axis planes ("planar" mapping - what floors, walls and boxes want).
  ============================================================================ }
unit hdeh_mesh;
{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fgl, Math, hdeh_math;

type
  TTextureMapping = (tmNone, tmPlanarX, tmPlanarY, tmPlanarZ, tmDirect);
  TTri = array[0..2] of LongInt;

  TMesh = class
  public
    Name: string;
    Positions: array of TVec3;
    Normals: array of TVec3;
    UVs: array of TVec2;
    Indices: array of LongInt;
    Mapping: TTextureMapping;
    MapScale: Single;              // world units per texture repeat
    MapOffset: TVec2;
    Bounds: TAABB;

    constructor Create;
    destructor Destroy; override;

    procedure Clear;
    procedure UpdateBounds;

    function VertexCount: LongInt; inline;
    function TriangleCount: LongInt; inline;

    function AddVertex(const P: TVec3): LongInt; overload;
    function AddVertex(const P, N: TVec3; const T: TVec2): LongInt; overload;
    function AddFace(const P0, P1, P2: TVec3): LongInt;
    function AddQuadFace(const P0, P1, P2, P3: TVec3): LongInt;
    procedure AddTriangle(I0, I1, I2: LongInt);
    procedure AddQuad(I0, I1, I2, I3: LongInt);
    procedure AddMesh(const Src: TMesh); overload;      // share vertices
    procedure AddMesh(const Src: TMesh; const M: TMat4); overload;

    procedure ComputeFaceNormals;
    procedure ComputeVertexNormals;                     // smooth, area weighted
    procedure SetPlanarMapping(Scale: Single);          // picks the flattest axis
    procedure SetMapping(M: TTextureMapping; Scale: Single);
    procedure ApplyMapping;
    procedure ScaleUV(SU, SV: Single);
    procedure Transform(const M: TMat4);
    procedure LoadOBJ(const FileName: string);
    procedure SaveOBJ(const FileName: string);
  end;

{ ------------------------------------------------------------ primitives -- }
function MakeBoxMesh(HalfSize: TVec3): TMesh;
function MakePlaneMesh(HalfSizeX, HalfSizeZ: Single; Subdivisions: LongInt): TMesh;
function MakeSphereMesh(Radius: Single; Subdivisions: LongInt): TMesh;   // icosphere
function MakeTorusMesh(MajorRadius, MinorRadius: Single;
                       MajorSegments, MinorSegments: LongInt): TMesh;
function MakeCylinderMesh(Radius, HalfHeight: Single; Segments: LongInt): TMesh;

{ Locale independent float parser ("1", "-2.5", ".5", "1e-3", "1E+2"). }
function ParseFloatDef(const S: string; Def: Single): Single;

implementation

{ ================================================================== mesh === }

constructor TMesh.Create;
begin
  inherited Create;
  Mapping := tmNone;
  MapScale := 1;
  MapOffset := Vec2(0, 0);
  Bounds := AABBEmpty;
end;

destructor TMesh.Destroy;
begin
  Clear;
  inherited Destroy;
end;

procedure TMesh.Clear;
begin
  SetLength(Positions, 0);
  SetLength(Normals, 0);
  SetLength(UVs, 0);
  SetLength(Indices, 0);
  Bounds := AABBEmpty;
end;

procedure TMesh.UpdateBounds;
var
  I: LongInt;
begin
  Bounds := AABBEmpty;
  for I := 0 to High(Positions) do
    Bounds := AABBExpand(Bounds, Positions[I]);
end;

function TMesh.VertexCount: LongInt;
begin
  Result := Length(Positions);
end;

function TMesh.TriangleCount: LongInt;
begin
  Result := Length(Indices) div 3;
end;

function TMesh.AddVertex(const P: TVec3): LongInt;
begin
  Result := Length(Positions);
  SetLength(Positions, Result + 1);
  SetLength(Normals, Result + 1);
  SetLength(UVs, Result + 1);
  Positions[Result] := P;
  Normals[Result] := Vec3UnitY;
  UVs[Result] := Vec2Zero;
  Bounds := AABBExpand(Bounds, P);
end;

function TMesh.AddVertex(const P, N: TVec3; const T: TVec2): LongInt;
begin
  Result := AddVertex(P);
  Normals[Result] := N;
  UVs[Result] := T;
end;

procedure TMesh.AddTriangle(I0, I1, I2: LongInt);
var
  N: LongInt;
begin
  N := Length(Indices);
  SetLength(Indices, N + 3);
  Indices[N] := I0;
  Indices[N + 1] := I1;
  Indices[N + 2] := I2;
end;

procedure TMesh.AddQuad(I0, I1, I2, I3: LongInt);
begin
  AddTriangle(I0, I1, I2);
  AddTriangle(I0, I2, I3);
end;

function TMesh.AddFace(const P0, P1, P2: TVec3): LongInt;
var
  N: TVec3;
  I0, I1, I2: LongInt;
begin
  N := Vec3Normalize(Vec3Cross(Vec3Sub(P1, P0), Vec3Sub(P2, P0)));
  I0 := AddVertex(P0, N, Vec2(0, 0));
  I1 := AddVertex(P1, N, Vec2(1, 0));
  I2 := AddVertex(P2, N, Vec2(0, 1));
  AddTriangle(I0, I1, I2);
  Result := I0;
end;

function TMesh.AddQuadFace(const P0, P1, P2, P3: TVec3): LongInt;
var
  N: TVec3;
  I0, I1, I2, I3: LongInt;
begin
  N := Vec3Normalize(Vec3Cross(Vec3Sub(P1, P0), Vec3Sub(P3, P0)));
  I0 := AddVertex(P0, N, Vec2(0, 0));
  I1 := AddVertex(P1, N, Vec2(1, 0));
  I2 := AddVertex(P2, N, Vec2(1, 1));
  I3 := AddVertex(P3, N, Vec2(0, 1));
  AddQuad(I0, I1, I2, I3);
  Result := I0;
end;

procedure TMesh.AddMesh(const Src: TMesh);
var
  Base, I, N: LongInt;
begin
  Base := Length(Positions);
  N := Length(Src.Positions);
  SetLength(Positions, Base + N);
  SetLength(Normals, Base + N);
  SetLength(UVs, Base + N);
  for I := 0 to N - 1 do
    begin
      Positions[Base + I] := Src.Positions[I];
      Normals[Base + I] := Src.Normals[I];
      UVs[Base + I] := Src.UVs[I];
    end;
  N := Length(Src.Indices);
  SetLength(Indices, Length(Indices) + N);
  for I := 0 to N - 1 do
    Indices[Length(Indices) - N + I] := Src.Indices[I] + Base;
  Bounds := AABBUnion(Bounds, Src.Bounds);
end;

procedure TMesh.AddMesh(const Src: TMesh; const M: TMat4);
var
  Base, I, N: LongInt;
  NM: TMat4;
begin
  NM := Mat4NormalMatrix(M);
  Base := Length(Positions);
  N := Length(Src.Positions);
  SetLength(Positions, Base + N);
  SetLength(Normals, Base + N);
  SetLength(UVs, Base + N);
  for I := 0 to N - 1 do
    begin
      Positions[Base + I] := Mat4MulPoint(M, Src.Positions[I]);
      Normals[Base + I] := Vec3Normalize(Mat4MulDir(NM, Src.Normals[I]));
      UVs[Base + I] := Src.UVs[I];
    end;
  N := Length(Src.Indices);
  SetLength(Indices, Length(Indices) + N);
  for I := 0 to N - 1 do
    Indices[Length(Indices) - N + I] := Src.Indices[I] + Base;
  UpdateBounds;
end;

procedure TMesh.ComputeFaceNormals;
var
  T, I0, I1, I2: LongInt;
  N: TVec3;
begin
  for T := 0 to TriangleCount - 1 do
    begin
      I0 := Indices[T * 3];
      I1 := Indices[T * 3 + 1];
      I2 := Indices[T * 3 + 2];
      N := Vec3Normalize(Vec3Cross(Vec3Sub(Positions[I1], Positions[I0]),
                                   Vec3Sub(Positions[I2], Positions[I0])));
      Normals[I0] := N;
      Normals[I1] := N;
      Normals[I2] := N;
    end;
end;

procedure TMesh.ComputeVertexNormals;
{ Area weighted smooth normals: the un-normalised cross product of two edges
  is proportional to the triangle area, so summing it gives the usual area
  weighted average of the adjacent face normals. }
var
  T, I, I0, I1, I2: LongInt;
  N: TVec3;
begin
  for I := 0 to High(Normals) do
    Normals[I] := Vec3Zero;
  for T := 0 to TriangleCount - 1 do
    begin
      I0 := Indices[T * 3];
      I1 := Indices[T * 3 + 1];
      I2 := Indices[T * 3 + 2];
      N := Vec3Cross(Vec3Sub(Positions[I1], Positions[I0]),
                     Vec3Sub(Positions[I2], Positions[I0]));
      Normals[I0] := Normals[I0] + N;
      Normals[I1] := Normals[I1] + N;
      Normals[I2] := Normals[I2] + N;
    end;
  for I := 0 to High(Normals) do
    Normals[I] := Vec3Normalize(Normals[I]);
end;

procedure TMesh.SetMapping(M: TTextureMapping; Scale: Single);
begin
  Mapping := M;
  MapScale := Scale;
  if Mapping <> tmDirect then
    ApplyMapping;
end;

procedure TMesh.SetPlanarMapping(Scale: Single);
var
  E: TVec3;
  Smallest: Single;
  Axis: TTextureMapping;
begin
  if not Bounds.Valid then Exit;
  E := AABBExtents(Bounds);
  Axis := tmPlanarY;
  Smallest := E.Y;
  if E.X < Smallest then
    begin
      Smallest := E.X;
      Axis := tmPlanarX;
    end;
  if E.Z < Smallest then
    Axis := tmPlanarZ;
  SetMapping(Axis, Scale);
end;

procedure TMesh.ApplyMapping;
var
  I: LongInt;
  P: TVec3;
begin
  for I := 0 to High(Positions) do
    begin
      P := Positions[I];
      case Mapping of
        tmPlanarX: UVs[I] := Vec2((P.Y + MapOffset.X) / MapScale, (P.Z + MapOffset.Y) / MapScale);
        tmPlanarY: UVs[I] := Vec2((P.X + MapOffset.X) / MapScale, (P.Z + MapOffset.Y) / MapScale);
        tmPlanarZ: UVs[I] := Vec2((P.X + MapOffset.X) / MapScale, (P.Y + MapOffset.Y) / MapScale);
      end;
    end;
end;

procedure TMesh.ScaleUV(SU, SV: Single);
var
  I: LongInt;
begin
  for I := 0 to High(UVs) do
    UVs[I] := Vec2(UVs[I].X * SU, UVs[I].Y * SV);
end;

procedure TMesh.Transform(const M: TMat4);
var
  I: LongInt;
  NM: TMat4;
begin
  NM := Mat4NormalMatrix(M);
  for I := 0 to High(Positions) do
    begin
      Normals[I] := Vec3Normalize(Mat4MulDir(NM, Normals[I]));
      Positions[I] := Mat4MulPoint(M, Positions[I]);
    end;
  UpdateBounds;
end;

{ -------------------------------------------------------------- OBJ input -- }

function ParseFloatDef(const S: string; Def: Single): Single;
var
  I, L: LongInt;
  Sign, Mantissa, Frac, Exp: Double;
  ExpSign: Double;
  Seen: Boolean;
begin
  Result := Def;
  L := Length(S);
  I := 1;
  while (I <= L) and (S[I] <= ' ') do Inc(I);
  if I > L then Exit;
  Sign := 1;
  if S[I] = '-' then
    begin
      Sign := -1;
      Inc(I);
    end
  else if S[I] = '+' then
    Inc(I);
  Mantissa := 0;
  Seen := False;
  while (I <= L) and (S[I] >= '0') and (S[I] <= '9') do
    begin
      Mantissa := Mantissa * 10 + (Ord(S[I]) - Ord('0'));
      Inc(I);
      Seen := True;
    end;
  if (I <= L) and (S[I] = '.') then
    begin
      Inc(I);
      Frac := 0.1;
      while (I <= L) and (S[I] >= '0') and (S[I] <= '9') do
        begin
          Mantissa := Mantissa + (Ord(S[I]) - Ord('0')) * Frac;
          Frac := Frac * 0.1;
          Inc(I);
          Seen := True;
        end;
    end;
  if not Seen then Exit;
  if (I <= L) and ((S[I] = 'e') or (S[I] = 'E')) then
    begin
      Inc(I);
      ExpSign := 1;
      if (I <= L) and (S[I] = '-') then
        begin
          ExpSign := -1;
          Inc(I);
        end
      else if (I <= L) and (S[I] = '+') then
        Inc(I);
      Exp := 0;
      while (I <= L) and (S[I] >= '0') and (S[I] <= '9') do
        begin
          Exp := Exp * 10 + (Ord(S[I]) - Ord('0'));
          Inc(I);
        end;
      Mantissa := Mantissa * Exp10(ExpSign * Exp);
    end;
  Result := Sign * Mantissa;
end;

function NextToken(const S: string; var P: LongInt): string;
begin
  while (P <= Length(S)) and (S[P] <= ' ') do Inc(P);
  Result := '';
  while (P <= Length(S)) and (S[P] > ' ') do
    begin
      Result := Result + S[P];
      Inc(P);
    end;
end;

function ParseObjIndex(const Tok: string; Count: LongInt): LongInt;
{ "12" -> 11, "-3" -> Count-3 (OBJ relative indices), "" -> -1 }
var
  V: LongInt;
begin
  Result := -1;
  if Tok = '' then Exit;
  V := Round(ParseFloatDef(Tok, 0));
  if V > 0 then Result := V - 1
  else if V < 0 then Result := Count + V;
end;

procedure TMesh.LoadOBJ(const FileName: string);
var
  Lines: TStringList;
  Cache: TStringList;
  LineNo, P, I, J, Corners: LongInt;
  Line, Kind, Tok, Part, Key: string;
  Verts: array of TVec3;
  Texs: array of TVec2;
  Norms: array of TVec3;
  Corner: array[0..63] of LongInt;
  VI, TI, NI, Cached: LongInt;
  Pos: LongInt;
  HaveNormals, HaveUVs: Boolean;
  N: TVec3;
begin
  Lines := TStringList.Create;
  Cache := TStringList.Create;
  try
    Cache.Sorted := True;
    Cache.Duplicates := dupIgnore;
    Lines.LoadFromFile(FileName);
    HaveNormals := False;
    HaveUVs := False;
    SetLength(Verts, 0);
    SetLength(Texs, 0);
    SetLength(Norms, 0);

    for LineNo := 0 to Lines.Count - 1 do
      begin
        Line := Lines[LineNo];
        P := 1;
        Kind := NextToken(Line, P);
        if Kind = 'v' then
          begin
            SetLength(Verts, Length(Verts) + 1);
            Verts[High(Verts)].X := ParseFloatDef(NextToken(Line, P), 0);
            Verts[High(Verts)].Y := ParseFloatDef(NextToken(Line, P), 0);
            Verts[High(Verts)].Z := ParseFloatDef(NextToken(Line, P), 0);
          end
        else if Kind = 'vt' then
          begin
            SetLength(Texs, Length(Texs) + 1);
            Texs[High(Texs)].X := ParseFloatDef(NextToken(Line, P), 0);
            Texs[High(Texs)].Y := ParseFloatDef(NextToken(Line, P), 0);
            HaveUVs := True;
          end
        else if Kind = 'vn' then
          begin
            SetLength(Norms, Length(Norms) + 1);
            Norms[High(Norms)].X := ParseFloatDef(NextToken(Line, P), 0);
            Norms[High(Norms)].Y := ParseFloatDef(NextToken(Line, P), 0);
            Norms[High(Norms)].Z := ParseFloatDef(NextToken(Line, P), 0);
            HaveNormals := True;
          end
        else if Kind = 'f' then
          begin
            Corners := 0;
            repeat
              Tok := NextToken(Line, P);
              if (Tok = '') or (Corners > 62) then Break;
              VI := -1;
              TI := -1;
              NI := -1;
              Pos := 1;
              J := 0;
              while (Pos <= Length(Tok)) and (J < 3) do
                begin
                  Part := '';
                  while (Pos <= Length(Tok)) and (Tok[Pos] <> '/') do
                    begin
                      Part := Part + Tok[Pos];
                      Inc(Pos);
                    end;
                  Inc(Pos);                       // skip '/'
                  case J of
                    0: VI := ParseObjIndex(Part, Length(Verts));
                    1: TI := ParseObjIndex(Part, Length(Texs));
                    2: NI := ParseObjIndex(Part, Length(Norms));
                  end;
                  Inc(J);
                end;
              if (VI < 0) or (VI > High(Verts)) then Continue;

              Key := IntToStr(VI) + '/' + IntToStr(TI) + '/' + IntToStr(NI);
              Cached := Cache.IndexOf(Key);
              if Cached < 0 then
                begin
                  N := Vec3UnitY;
                  if (NI >= 0) and (NI <= High(Norms)) then N := Norms[NI];
                  VI := AddVertex(Verts[VI], N, Vec2Zero);
                  if (TI >= 0) and (TI <= High(Texs)) then UVs[VI] := Texs[TI];
                  Cache.AddObject(Key, TObject(PtrInt(VI)));
                  Cached := VI;
                end
              else
                Cached := PtrInt(Cache.Objects[Cached]);
              Corner[Corners] := Cached;
              Inc(Corners);
            until False;
            for J := 1 to Corners - 2 do
              AddTriangle(Corner[0], Corner[J], Corner[J + 1]);
          end;
      end;
  finally
    Lines.Free;
    Cache.Free;
  end;

  Name := ExtractFileName(FileName);
  UpdateBounds;
  if not HaveNormals then
    ComputeVertexNormals;
  if HaveUVs then
    begin
      Mapping := tmDirect;
      MapScale := 1;
    end
  else
    SetPlanarMapping(1);
end;

procedure TMesh.SaveOBJ(const FileName: string);
var
  S: TStringList;
  I, T: LongInt;
begin
  S := TStringList.Create;
  try
    S.Add('# written by the hdeh 3D engine');
    S.Add(Format('# vertices: %d  triangles: %d', [VertexCount, TriangleCount]));
    for I := 0 to High(Positions) do
      S.Add(Format('v %.6f %.6f %.6f', [Positions[I].X, Positions[I].Y, Positions[I].Z]));
    for I := 0 to High(UVs) do
      S.Add(Format('vt %.6f %.6f', [UVs[I].X, UVs[I].Y]));
    for I := 0 to High(Normals) do
      S.Add(Format('vn %.6f %.6f %.6f', [Normals[I].X, Normals[I].Y, Normals[I].Z]));
    for T := 0 to TriangleCount - 1 do
      S.Add(Format('f %d/%d/%d %d/%d/%d %d/%d/%d',
        [Indices[T * 3] + 1, Indices[T * 3] + 1, Indices[T * 3] + 1,
         Indices[T * 3 + 1] + 1, Indices[T * 3 + 1] + 1, Indices[T * 3 + 1] + 1,
         Indices[T * 3 + 2] + 1, Indices[T * 3 + 2] + 1, Indices[T * 3 + 2] + 1]));
    S.SaveToFile(FileName);
  finally
    S.Free;
  end;
end;

{ ============================================================= primitives == }

function MakeBoxMesh(HalfSize: TVec3): TMesh;
const
  // 8 corners, bit 0 = x, bit 1 = y, bit 2 = z
  Faces: array[0..5] of array[0..3] of LongInt =
    ((4, 5, 7, 6),   // +X
     (1, 0, 2, 3),   // -X
     (2, 3, 7, 6),   // +Y
     (0, 1, 5, 4),   // -Y
     (0, 4, 6, 2),   // +Z
     (1, 3, 7, 5));  // -Z
  FaceNormal: array[0..5] of TVec3 =
    ((X: 1; Y: 0; Z: 0), (X: -1; Y: 0; Z: 0),
     (X: 0; Y: 1; Z: 0), (X: 0; Y: -1; Z: 0),
     (X: 0; Y: 0; Z: 1), (X: 0; Y: 0; Z: -1));
  FaceUV: array[0..3] of TVec2 =
    ((X: 0; Y: 0), (X: 1; Y: 0), (X: 1; Y: 1), (X: 0; Y: 1));
var
  Corners: array[0..7] of TVec3;
  FaceIdx: array[0..3] of LongInt;
  I, F, C: LongInt;
begin
  Result := TMesh.Create;
  Result.Name := 'box';
  for I := 0 to 7 do
    begin
      if (I and 1) = 0 then Corners[I].X := -HalfSize.X else Corners[I].X := HalfSize.X;
      if (I and 2) = 0 then Corners[I].Y := -HalfSize.Y else Corners[I].Y := HalfSize.Y;
      if (I and 4) = 0 then Corners[I].Z := -HalfSize.Z else Corners[I].Z := HalfSize.Z;
    end;
  for F := 0 to 5 do
    begin
      for C := 0 to 3 do
        FaceIdx[C] := Result.AddVertex(Corners[Faces[F][C]], FaceNormal[F], FaceUV[C]);
      Result.AddQuad(FaceIdx[0], FaceIdx[1], FaceIdx[2], FaceIdx[3]);
    end;
  Result.UpdateBounds;
  Result.Mapping := tmDirect;
  Result.MapScale := 1;
end;

function MakePlaneMesh(HalfSizeX, HalfSizeZ: Single; Subdivisions: LongInt): TMesh;
var
  IX, IZ, N: LongInt;
  U, V: Single;
  P: TVec3;
  Grid: array of LongInt;
begin
  Result := TMesh.Create;
  Result.Name := 'plane';
  if Subdivisions < 1 then Subdivisions := 1;
  N := Subdivisions;
  SetLength(Grid, (N + 1) * (N + 1));
  for IZ := 0 to N do
    for IX := 0 to N do
      begin
        U := IX / N;
        V := IZ / N;
        P := Vec3(U * 2 * HalfSizeX - HalfSizeX, 0, V * 2 * HalfSizeZ - HalfSizeZ);
        // UVs are world coordinates: the caller sets the texture size in
        // world units by scaling them (see Mesh.ScaleUV / material.TextureScale)
        Grid[IZ * (N + 1) + IX] := Result.AddVertex(P, Vec3UnitY, Vec2(P.X, P.Z));
      end;
  for IZ := 0 to N - 1 do
    for IX := 0 to N - 1 do
      Result.AddQuad(Grid[IZ * (N + 1) + IX],
                     Grid[IZ * (N + 1) + IX + 1],
                     Grid[(IZ + 1) * (N + 1) + IX + 1],
                     Grid[(IZ + 1) * (N + 1) + IX]);
  Result.UpdateBounds;
  Result.Mapping := tmDirect;
  Result.MapScale := 1;
end;

function MakeSphereMesh(Radius: Single; Subdivisions: LongInt): TMesh;
type
  TEdgeMap = specialize TFPGMap<QWord, LongInt>;
var
  Verts: array of TVec3;
  Tris: array of TTri;
  EdgeMap: TEdgeMap;
  Level, I: LongInt;
  T: Single;
  P, Mid: TVec3;
  Key: QWord;
  A, B, C, AB, BC, CA: LongInt;
  NewTris: array of TTri;

  function SplitEdge(I0, I1: LongInt): LongInt;
  var
    Lo, Hi, Found: LongInt;
  begin
    if I0 < I1 then
      begin
        Lo := I0;
        Hi := I1;
      end
    else
      begin
        Lo := I1;
        Hi := I0;
      end;
    Key := (QWord(Lo) shl 32) or QWord(Hi);
    Found := EdgeMap.IndexOf(Key);
    if Found >= 0 then
      Exit(EdgeMap.Data[Found]);
    Mid := Vec3Scale(Vec3Add(Verts[Lo], Verts[Hi]), 0.5);
    Mid := Vec3Scale(Vec3Normalize(Mid), Radius);
    Result := Length(Verts);
    SetLength(Verts, Result + 1);
    Verts[Result] := Mid;
    EdgeMap.Add(Key, Result);
  end;

begin
  if Subdivisions < 0 then Subdivisions := 0;
  if Subdivisions > 5 then Subdivisions := 5;

  // ---- icosahedron with the classic 12 vertex / 20 face layout ----
  T := (1 + Sqrt(5)) / 2;
  SetLength(Verts, 12);
  Verts[0] := Vec3(-1, T, 0);
  Verts[1] := Vec3(1, T, 0);
  Verts[2] := Vec3(-1, -T, 0);
  Verts[3] := Vec3(1, -T, 0);
  Verts[4] := Vec3(0, -1, T);
  Verts[5] := Vec3(0, 1, T);
  Verts[6] := Vec3(0, -1, -T);
  Verts[7] := Vec3(0, 1, -T);
  Verts[8] := Vec3(T, 0, -1);
  Verts[9] := Vec3(T, 0, 1);
  Verts[10] := Vec3(-T, 0, -1);
  Verts[11] := Vec3(-T, 0, 1);
  for I := 0 to 11 do
    Verts[I] := Vec3Scale(Vec3Normalize(Verts[I]), Radius);

  SetLength(Tris, 20);
  Tris[0][0] := 0;  Tris[0][1] := 11; Tris[0][2] := 5;
  Tris[1][0] := 0;  Tris[1][1] := 5;  Tris[1][2] := 1;
  Tris[2][0] := 0;  Tris[2][1] := 1;  Tris[2][2] := 7;
  Tris[3][0] := 0;  Tris[3][1] := 7;  Tris[3][2] := 10;
  Tris[4][0] := 0;  Tris[4][1] := 10; Tris[4][2] := 11;
  Tris[5][0] := 1;  Tris[5][1] := 5;  Tris[5][2] := 9;
  Tris[6][0] := 5;  Tris[6][1] := 11; Tris[6][2] := 4;
  Tris[7][0] := 11; Tris[7][1] := 10; Tris[7][2] := 2;
  Tris[8][0] := 10; Tris[8][1] := 7;  Tris[8][2] := 6;
  Tris[9][0] := 7;  Tris[9][1] := 1;  Tris[9][2] := 8;
  Tris[10][0] := 3; Tris[10][1] := 9; Tris[10][2] := 4;
  Tris[11][0] := 3; Tris[11][1] := 4; Tris[11][2] := 2;
  Tris[12][0] := 3; Tris[12][1] := 2; Tris[12][2] := 6;
  Tris[13][0] := 3; Tris[13][1] := 6; Tris[13][2] := 8;
  Tris[14][0] := 3; Tris[14][1] := 8; Tris[14][2] := 9;
  Tris[15][0] := 4; Tris[15][1] := 9; Tris[15][2] := 5;
  Tris[16][0] := 2; Tris[16][1] := 4; Tris[16][2] := 11;
  Tris[17][0] := 6; Tris[17][1] := 2; Tris[17][2] := 10;
  Tris[18][0] := 8; Tris[18][1] := 6; Tris[18][2] := 7;
  Tris[19][0] := 9; Tris[19][1] := 8; Tris[19][2] := 1;

  // ---- subdivide: every triangle becomes four ----
  EdgeMap := TEdgeMap.Create;
  try
    for Level := 1 to Subdivisions do
      begin
        EdgeMap.Clear;
        SetLength(NewTris, Length(Tris) * 4);
        for I := 0 to High(Tris) do
          begin
            A := Tris[I][0];
            B := Tris[I][1];
            C := Tris[I][2];
            AB := SplitEdge(A, B);
            BC := SplitEdge(B, C);
            CA := SplitEdge(C, A);
            NewTris[I * 4 + 0][0] := A;  NewTris[I * 4 + 0][1] := AB; NewTris[I * 4 + 0][2] := CA;
            NewTris[I * 4 + 1][0] := B;  NewTris[I * 4 + 1][1] := BC; NewTris[I * 4 + 1][2] := AB;
            NewTris[I * 4 + 2][0] := C;  NewTris[I * 4 + 2][1] := CA; NewTris[I * 4 + 2][2] := BC;
            NewTris[I * 4 + 3][0] := AB; NewTris[I * 4 + 3][1] := BC; NewTris[I * 4 + 3][2] := CA;
          end;
        SetLength(Tris, Length(NewTris));
        for I := 0 to High(NewTris) do
          Tris[I] := NewTris[I];
      end;
  finally
    EdgeMap.Free;
  end;

  // ---- convert to a mesh with smooth (spherical) normals ----
  Result := TMesh.Create;
  Result.Name := 'sphere';
  SetLength(Result.Positions, Length(Verts));
  SetLength(Result.Normals, Length(Verts));
  SetLength(Result.UVs, Length(Verts));
  for I := 0 to High(Verts) do
    begin
      P := Verts[I];
      Result.Positions[I] := P;
      Result.Normals[I] := Vec3Normalize(P);
      Result.UVs[I] := Vec2(0.5 + ArcTan2(P.Z, P.X) / (2 * Pi),
                            0.5 + ArcSin(ClampS(P.Y / Radius, -1, 1)) / Pi);
    end;
  SetLength(Result.Indices, Length(Tris) * 3);
  for I := 0 to High(Tris) do
    begin
      Result.Indices[I * 3 + 0] := Tris[I][0];
      Result.Indices[I * 3 + 1] := Tris[I][1];
      Result.Indices[I * 3 + 2] := Tris[I][2];
    end;
  Result.UpdateBounds;
  Result.Mapping := tmDirect;
  Result.MapScale := 1;
end;

function MakeTorusMesh(MajorRadius, MinorRadius: Single;
  MajorSegments, MinorSegments: LongInt): TMesh;
var
  I, J, A, B, C, D: LongInt;
  U, V: Single;
  Center, N, P: TVec3;
  Rows: array of array of LongInt;
begin
  Result := TMesh.Create;
  Result.Name := 'torus';
  if MajorSegments < 3 then MajorSegments := 3;
  if MinorSegments < 3 then MinorSegments := 3;
  SetLength(Rows, MajorSegments);
  for I := 0 to MajorSegments - 1 do
    begin
      U := I * 2 * Pi / MajorSegments;
      Center := Vec3(Cos(U) * MajorRadius, 0, Sin(U) * MajorRadius);
      SetLength(Rows[I], MinorSegments + 1);
      for J := 0 to MinorSegments do
        begin
          V := J * 2 * Pi / MinorSegments;
          N := Vec3(Cos(U) * Cos(V), Sin(V), Sin(U) * Cos(V));
          P := Center + Vec3Scale(N, MinorRadius);
          Rows[I][J] := Result.AddVertex(P, N, Vec2(I / MajorSegments, J / MinorSegments));
        end;
    end;
  for I := 0 to MajorSegments - 1 do
    for J := 0 to MinorSegments - 1 do
      begin
        A := Rows[I][J];
        B := Rows[(I + 1) mod MajorSegments][J];
        C := Rows[(I + 1) mod MajorSegments][J + 1];
        D := Rows[I][J + 1];
        Result.AddQuad(A, B, C, D);
      end;
  Result.UpdateBounds;
  Result.Mapping := tmDirect;
  Result.MapScale := 1;
end;

function MakeCylinderMesh(Radius, HalfHeight: Single; Segments: LongInt): TMesh;
var
  I: LongInt;
  U, U2: Single;
  Bottom, Top: array of LongInt;
  CapBottom, CapTop, V1, V2, V3, V4: LongInt;
begin
  Result := TMesh.Create;
  Result.Name := 'cylinder';
  if Segments < 3 then Segments := 3;
  SetLength(Bottom, Segments);
  SetLength(Top, Segments);
  for I := 0 to Segments - 1 do
    begin
      U := I * 2 * Pi / Segments;
      Bottom[I] := Result.AddVertex(Vec3(Cos(U) * Radius, -HalfHeight, Sin(U) * Radius),
        Vec3(Cos(U), 0, Sin(U)), Vec2(I / Segments, 0));
      Top[I] := Result.AddVertex(Vec3(Cos(U) * Radius, HalfHeight, Sin(U) * Radius),
        Vec3(Cos(U), 0, Sin(U)), Vec2(I / Segments, 1));
    end;
  for I := 0 to Segments - 1 do
    Result.AddQuad(Bottom[I], Bottom[(I + 1) mod Segments],
                   Top[(I + 1) mod Segments], Top[I]);

  CapBottom := Result.AddVertex(Vec3(0, -HalfHeight, 0), Vec3(0, -1, 0), Vec2(0.5, 0.5));
  CapTop := Result.AddVertex(Vec3(0, HalfHeight, 0), Vec3(0, 1, 0), Vec2(0.5, 0.5));
  for I := 0 to Segments - 1 do
    begin
      U := I * 2 * Pi / Segments;
      U2 := (I + 1) * 2 * Pi / Segments;
      V1 := Result.AddVertex(Vec3(Cos(U) * Radius, -HalfHeight, Sin(U) * Radius),
        Vec3(0, -1, 0), Vec2(0.5 + Cos(U) * 0.5, 0.5 + Sin(U) * 0.5));
      V2 := Result.AddVertex(Vec3(Cos(U2) * Radius, -HalfHeight, Sin(U2) * Radius),
        Vec3(0, -1, 0), Vec2(0.5 + Cos(U2) * 0.5, 0.5 + Sin(U2) * 0.5));
      Result.AddTriangle(CapBottom, V1, V2);
      V3 := Result.AddVertex(Vec3(Cos(U2) * Radius, HalfHeight, Sin(U2) * Radius),
        Vec3(0, 1, 0), Vec2(0.5 + Cos(U2) * 0.5, 0.5 + Sin(U2) * 0.5));
      V4 := Result.AddVertex(Vec3(Cos(U) * Radius, HalfHeight, Sin(U) * Radius),
        Vec3(0, 1, 0), Vec2(0.5 + Cos(U) * 0.5, 0.5 + Sin(U) * 0.5));
      Result.AddTriangle(CapTop, V3, V4);
    end;
  Result.UpdateBounds;
  Result.Mapping := tmDirect;
  Result.MapScale := 1;
end;

end.
