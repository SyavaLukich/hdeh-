{ ============================================================================
  hdeh-raster - the software rasterizer.

  Pipeline per triangle:

      model space --> clip space (model * view * projection)
                  --> near plane clipping (Sutherland-Hodgman)
                  --> viewport mapping
                  --> scanline/edge-function rasterization with a z buffer
                  --> perspective correct interpolation of world position,
                      normal and texture coordinates
                  --> fragment shading (built in Phong/Blinn or a callback)

  The colour buffer keeps linear (unclamped) RGB floats; gamma and clamping
  happen only in ToImage, which is what a display backend calls.  The depth
  buffer stores NDC z mapped to [0,1], 0 being the near plane.

  Wireframe and vertex points are drawn as an overlay in the very same pass
  (depth tested, no depth writes), which keeps them perfectly in sync with
  the shaded geometry.
  ============================================================================ }
unit hdeh_raster;
{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, hdeh_math, hdeh_image, hdeh_mesh, hdeh_scene;

const
  MaxLights = 8;
  MaxShadowMaps = 2;

type
  TCullMode = (cmNone, cmBack, cmFront);
  TRasterMode = (rmColor, rmDepth);

  TClipVertex = record
    Clip: TVec4;         // clip space, w > 0 after clipping
    World: TVec3;
    Normal: TVec3;
    UV: TVec2;
  end;

  TShadowMap = class
  private
    FSize: LongInt;
    FData: array of Single;
  public
    constructor Create(ASize: LongInt);
    destructor Destroy; override;
    procedure Clear;
    property Size: LongInt read FSize;
    function GetDepth(X, Y: LongInt): Single; inline;
    procedure SetDepth(X, Y: LongInt; D: Single); inline;
    { Percentage of shadow map samples in the 3x3 neighbourhood that are
      closer to the light than CompareDepth.  1 = fully lit, 0 = fully
      shadowed, values in between are the soft edge. }
    function SamplePCF(U, V, CompareDepth, Bias: Single): Single;
  end;

  TShadowSource = record
    Active: Boolean;
    Light: TLight;
    ViewProj: TMat4;
    Map: TShadowMap;
    Strength: Single;
  end;

  TFragment = record
    World: TVec3;
    Normal: TVec3;
    UV: TVec2;
    Color: TVec3;         // albedo of the material
    Depth: Single;        // eye space distance
    ScreenX, ScreenY: LongInt;
    Material: TMaterial;
    Node: TNode;
    Triangle: LongInt;
  end;

  TFrameContext = record
    ViewProj: TMat4;
    View: TMat4;
    Eye: TVec3;
    Ambient: TVec3;
    Lights: array[0..MaxLights - 1] of TLight;
    LightCount: LongInt;
    ShadowCount: LongInt;
    Shadows: array[0..MaxShadowMaps - 1] of TShadowSource;
    FogColor: TVec3;
    FogDensity: Single;
    FogStart: Single;
    Time: Single;
    Camera: TCamera;
  end;

  TFragShadeFunc = function(const F: TFragment): TVec3 of object;

  TRenderSettings = record
    Fill: Boolean;                 // draw filled triangles
    Wireframe: Boolean;            // overlay wireframe
    WireColor: TVec3;
    WireWidth: Single;             // in pixels
    Points: Boolean;               // draw vertices as points
    PointColor: TVec3;
    Lighting: Boolean;
    Textures: Boolean;
    NormalMaps: Boolean;
    Fog: Boolean;
    Shadows: Boolean;
    CullMode: TCullMode;
    DepthTest: Boolean;
    DepthWrite: Boolean;
    PerspectiveCorrect: Boolean;
    ShadowBias: Single;            // depth map compare bias
    ShadowNormalBias: Single;      // world space offset along the normal
    AmbientScale: Single;
  end;

  TRenderStats = record
    TrianglesSubmitted: LongInt;
    TrianglesDrawn: LongInt;
    NodesDrawn: LongInt;
    NodesCulled: LongInt;
    PixelsShaded: LongInt;
    Pixels: LongInt;
  end;

const
  DefaultRenderSettings: TRenderSettings = (
    Fill: True;
    Wireframe: False;
    WireColor: (X: 0.05; Y: 0.05; Z: 0.06);
    WireWidth: 1;
    Points: False;
    PointColor: (X: 1; Y: 1; Z: 1);
    Lighting: True;
    Textures: True;
    NormalMaps: True;
    Fog: True;
    Shadows: True;
    CullMode: cmBack;
    DepthTest: True;
    DepthWrite: True;
    PerspectiveCorrect: True;
    ShadowBias: 0.0016;
    ShadowNormalBias: 0.05;
    AmbientScale: 1;
  );

type
  TRenderer = class
  private
    FWidth, FHeight: LongInt;
    FColor: array of TVec3;
    FDepth: array of Single;
    FContext: TFrameContext;
    FStats: TRenderStats;
    FCurNode: TNode;
    FCurMaterial: TMaterial;
    FTriIndex: LongInt;
    FDepthOnly: Boolean;
    FDepthSwap: array of Single;
    FShadowMaps: array[0..MaxShadowMaps - 1] of TShadowMap;

    procedure RasterizeTriangle(const A, B, C: TClipVertex; Mode: TRasterMode);
    procedure EmitTriangle(const A, B, C: TClipVertex; Mode: TRasterMode);
    procedure DrawMeshInternal(const Mesh: TMesh; const Model: TMat4;
      Mat: TMaterial; Node: TNode; const ViewProj: TMat4; Mode: TRasterMode);
  public
    Settings: TRenderSettings;
    OnFragment: TFragShadeFunc;      // nil = built in shading

    constructor Create(AWidth, AHeight: LongInt);
    destructor Destroy; override;
    procedure Resize(AWidth, AHeight: LongInt);

    property Width: LongInt read FWidth;
    property Height: LongInt read FHeight;
    property Context: TFrameContext read FContext;
    property Stats: TRenderStats read FStats;
    function ShadowMap(Index: LongInt): TShadowMap; inline;
    procedure ResetStats;

    procedure ClearDepth;
    procedure Clear(const TopColor, BottomColor: TVec3); overload;
    procedure Clear(const Color: TVec3); overload;

    procedure BeginFrame(Scene: TScene; Camera: TCamera);
    procedure DrawScene(Scene: TScene);
    procedure DrawNode(N: TNode);
    procedure DrawMesh(const Mesh: TMesh; const Model: TMat4; Mat: TMaterial);
    procedure SetShadowSource(Index: LongInt; Light: TLight; const ViewProj: TMat4;
      Map: TShadowMap; Strength: Single);
    procedure ClearShadowSources;
    procedure RenderDepthOnly(Scene: TScene; const ViewProj: TMat4; Map: TShadowMap;
      const Cull: TCullMode; DepthBias: Single);

    function ShadeDefault(const F: TFragment): TVec3;
    function ShadowFactorAt(const P: TVec3; const N: TVec3; Light: TLight): Single;

    function ProjectPoint(const P: TVec3; out X, Y: LongInt; out Depth: Single): Boolean;
    procedure DrawPoint3D(const P: TVec3; const Color: TVec3);
    procedure DrawLine3D(const A, B: TVec3; const Color: TVec3);
    procedure SetPixelSafe(X, Y: LongInt; const Color: TVec3);
    procedure FillRect2D(X, Y, W, H: LongInt; const Color: TVec3; Alpha: Single);
    procedure ToImage(Img: TImage);
    function ColorAt(X, Y: LongInt): TVec3;
  end;

{ Fog amount for an eye space distance, 1 = fully fogged. }
function FogAmountFor(Depth, Start, Density: Single): Single;

implementation

function FogAmountFor(Depth, Start, Density: Single): Single;
var
  D: Single;
begin
  if Density <= 0 then
    Exit(0);
  D := Depth - Start;
  if D <= 0 then
    Exit(0);
  Result := 1 - Exp(-Sqr(D * Density));
  Result := ClampS(Result, 0, 1);
end;

{ ============================================================ shadow map === }

constructor TShadowMap.Create(ASize: LongInt);
begin
  inherited Create;
  FSize := ASize;
  SetLength(FData, FSize * FSize);
  Clear;
end;

destructor TShadowMap.Destroy;
begin
  SetLength(FData, 0);
  inherited Destroy;
end;

procedure TShadowMap.Clear;
var
  I: LongInt;
begin
  for I := 0 to High(FData) do
    FData[I] := 1;
end;

function TShadowMap.GetDepth(X, Y: LongInt): Single;
begin
  Result := FData[Y * FSize + X];
end;

procedure TShadowMap.SetDepth(X, Y: LongInt; D: Single);
begin
  FData[Y * FSize + X] := D;
end;

function TShadowMap.SamplePCF(U, V, CompareDepth, Bias: Single): Single;
var
  X, Y, DX, DY, Hits, Samples: LongInt;
  D: Single;
begin
  X := Floor(U * FSize);
  Y := Floor(V * FSize);
  Hits := 0;
  Samples := 0;
  for DY := -1 to 1 do
    for DX := -1 to 1 do
      begin
        if (X + DX < 0) or (X + DX >= FSize) or (Y + DY < 0) or (Y + DY >= FSize) then
          Continue;
        Inc(Samples);
        D := FData[(Y + DY) * FSize + (X + DX)];
        if CompareDepth - Bias <= D then
          Inc(Hits);
      end;
  if Samples = 0 then
    Result := 1
  else
    Result := Hits / Samples;
end;

{ ================================================================ renderer = }

constructor TRenderer.Create(AWidth, AHeight: LongInt);
var
  I: LongInt;
begin
  inherited Create;
  Settings := DefaultRenderSettings;
  OnFragment := nil;
  FWidth := AWidth;
  FHeight := AHeight;
  SetLength(FColor, FWidth * FHeight);
  SetLength(FDepth, FWidth * FHeight);
  for I := 0 to MaxShadowMaps - 1 do
    begin
      FShadowMaps[I] := TShadowMap.Create(512);
      FContext.Shadows[I].Active := False;
      FContext.Shadows[I].Map := FShadowMaps[I];
    end;
  FContext.ShadowCount := 0;
  FContext.LightCount := 0;
  FillChar(FStats, SizeOf(FStats), 0);
  Clear(Vec3(0, 0, 0));
end;

destructor TRenderer.Destroy;
var
  I: LongInt;
begin
  for I := 0 to MaxShadowMaps - 1 do
    FShadowMaps[I].Free;
  SetLength(FColor, 0);
  SetLength(FDepth, 0);
  inherited Destroy;
end;

procedure TRenderer.Resize(AWidth, AHeight: LongInt);
begin
  if (AWidth < 1) or (AHeight < 1) then Exit;
  FWidth := AWidth;
  FHeight := AHeight;
  SetLength(FColor, FWidth * FHeight);
  SetLength(FDepth, FWidth * FHeight);
  ClearDepth;
end;

function TRenderer.ShadowMap(Index: LongInt): TShadowMap;
begin
  Result := FShadowMaps[Index];
end;

procedure TRenderer.ResetStats;
begin
  FillChar(FStats, SizeOf(FStats), 0);
  FStats.Pixels := FWidth * FHeight;
end;

procedure TRenderer.ClearDepth;
var
  I: LongInt;
begin
  for I := 0 to High(FDepth) do
    FDepth[I] := 1;
end;

procedure TRenderer.Clear(const Color: TVec3);
begin
  Clear(Color, Color);
end;

procedure TRenderer.Clear(const TopColor, BottomColor: TVec3);
var
  X, Y: LongInt;
  T: Single;
  C: TVec3;
begin
  for Y := 0 to FHeight - 1 do
    begin
      T := Y / (FHeight - 1 + 1E-6);
      C := Vec3Lerp(TopColor, BottomColor, T);
      for X := 0 to FWidth - 1 do
        FColor[Y * FWidth + X] := C;
    end;
  ClearDepth;
end;

procedure TRenderer.FillRect2D(X, Y, W, H: LongInt; const Color: TVec3; Alpha: Single);
var
  PX, PY, X0, X1, Y0, Y1: LongInt;
  C: TVec3;
begin
  X0 := ClampI(X, 0, FWidth - 1);
  Y0 := ClampI(Y, 0, FHeight - 1);
  X1 := ClampI(X + W - 1, 0, FWidth - 1);
  Y1 := ClampI(Y + H - 1, 0, FHeight - 1);
  Alpha := ClampS(Alpha, 0, 1);
  for PY := Y0 to Y1 do
    for PX := X0 to X1 do
      begin
        C := FColor[PY * FWidth + PX];
        FColor[PY * FWidth + PX] := Vec3Lerp(C, Color, Alpha);
      end;
end;

procedure TRenderer.SetPixelSafe(X, Y: LongInt; const Color: TVec3);
begin
  if (X < 0) or (X >= FWidth) or (Y < 0) or (Y >= FHeight) then Exit;
  FColor[Y * FWidth + X] := Color;
end;

function TRenderer.ColorAt(X, Y: LongInt): TVec3;
begin
  if (X < 0) or (X >= FWidth) or (Y < 0) or (Y >= FHeight) then
    Result := Vec3Zero
  else
    Result := FColor[Y * FWidth + X];
end;

procedure TRenderer.ToImage(Img: TImage);
var
  X, Y: LongInt;
begin
  if (Img.Width <> FWidth) or (Img.Height <> FHeight) then
    raise Exception.CreateFmt('ToImage: image is %dx%d, framebuffer is %dx%d',
      [Img.Width, Img.Height, FWidth, FHeight]);
  for Y := 0 to FHeight - 1 do
    for X := 0 to FWidth - 1 do
      Img[X, Y] := RGBAFromVec(FColor[Y * FWidth + X]);
end;

{ --------------------------------------------------------------- shading --- }

function TRenderer.ShadowFactorAt(const P: TVec3; const N: TVec3; Light: TLight): Single;
var
  I: LongInt;
  Src: TShadowSource;
  Offset: TVec3;
  L: TVec3;
  NdL: Single;
  SP: TVec4;
  U, V, D: Single;
begin
  Result := 1;
  if not Settings.Shadows then Exit;
  for I := 0 to FContext.ShadowCount - 1 do
    begin
      Src := FContext.Shadows[I];
      if (not Src.Active) or (Src.Light <> Light) or (Src.Map = nil) then Continue;

      if Light.Kind = lkDirectional then
        L := Vec3Neg(Light.Direction)
      else
        L := Vec3Normalize(Vec3Sub(Light.Position, P));
      NdL := Vec3Dot(N, L);
      Offset := Vec3Scale(N, Settings.ShadowNormalBias * (1 - ClampS(NdL, 0, 1)) * 3);
      SP := Mat4MulPoint4(Src.ViewProj, P + Offset);
      if SP.W <= 1E-5 then Continue;
      U := SP.X / SP.W * 0.5 + 0.5;
      V := 0.5 - SP.Y / SP.W * 0.5;      // texture V is flipped
      D := SP.Z / SP.W * 0.5 + 0.5;
      if (U < 0) or (U > 1) or (V < 0) or (V > 1) or (D > 1) then Continue;
      Result := Result * Src.Map.SamplePCF(U, V, D, Settings.ShadowBias);
    end;
  if Result < 0 then Result := 0;
end;

function TRenderer.ShadeDefault(const F: TFragment): TVec3;
var
  Mat: TMaterial;
  Albedo, N, V, L, H, Diff, Spec, Lit: TVec3;
  I, Kind: LongInt;
  Lt: TLight;
  Texel: TRGBA;
  Att, NdL, Spot, CosAngle: Single;
  Shadow, Fog: Single;
begin
  Mat := F.Material;
  Albedo := Mat.Color;

  if (Mat.Texture <> nil) and Settings.Textures then
    begin
      Texel := Mat.Texture.SampleBilinear(F.UV.X, F.UV.Y);
      Albedo := Albedo * ColToVec(Texel);
    end;

  N := Vec3Normalize(F.Normal);
  V := Vec3Normalize(Vec3Sub(FContext.Eye, F.World));
  if Mat.DoubleSided then
    N := Vec3FaceForward(N, V);
  if Vec3LengthSq(N) < 1E-12 then
    N := Vec3UnitY;

  if not Settings.Lighting then
    begin
      Lit := Albedo * (1 + Mat.Emissive);
    end
  else
    begin
      Lit := Vec3Scale(Albedo * FContext.Ambient, Settings.AmbientScale) +
             Vec3Scale(Albedo, Mat.Emissive);
      for I := 0 to FContext.LightCount - 1 do
        begin
          Lt := FContext.Lights[I];
          Kind := Ord(Lt.Kind);
          if Kind = Ord(lkDirectional) then
            begin
              L := Vec3Neg(Lt.Direction);
              Att := Lt.Intensity;
              Spot := 1;
            end
          else
            begin
              L := Vec3Sub(Lt.Position, F.World);
              Att := Lt.Intensity / (1 + Vec3LengthSq(L) / Sqr(Lt.Range));
              L := Vec3Normalize(L);
              Spot := 1;
              if Kind = Ord(lkSpot) then
                begin
                  CosAngle := Vec3Dot(Vec3Neg(L), Lt.Direction);
                  if CosAngle < Cos(Lt.OuterAngle * Pi / 180) then
                    Spot := 0
                  else if Lt.OuterAngle - Lt.InnerAngle < 1E-3 then
                    Spot := 1
                  else
                    Spot := SmoothStepS(Cos(Lt.OuterAngle * Pi / 180),
                                        Cos(Lt.InnerAngle * Pi / 180), CosAngle);
                end;
            end;
          if (Att <= 0) or (Spot <= 0) then Continue;

          NdL := Vec3Dot(N, L);
          if NdL <= 0 then Continue;

          Shadow := 1;
          if Settings.Shadows then
            Shadow := ShadowFactorAt(F.World + Vec3Scale(N, 1E-3), N, Lt);

          Diff := Vec3Scale(Lt.Color, Att * NdL * Shadow);
          Lit := Lit + Albedo * Diff;

          if Mat.Specular > 0 then
            begin
              H := Vec3Normalize(L + V);
              Spec := Power(MaxS(Vec3Dot(N, H), 0), Mat.Shininess) * Mat.Specular * Shadow;
              if Mat.Shininess <= 0 then Spec := 0;
              Lit := Lit + Vec3Scale(Lt.Color * Att, Spec);
            end;
        end;
    end;

  if Settings.Fog and (FContext.FogDensity > 0) then
    begin
      Fog := FogAmountFor(F.Depth, FContext.FogStart, FContext.FogDensity);
      Lit := Vec3Lerp(Lit, FContext.FogColor, Fog);
    end;

  Result := Lit;
end;

{ ------------------------------------------------------- triangle setup --- }


{ --------------------------------------------------------------- frames --- }

procedure TRenderer.BeginFrame(Scene: TScene; Camera: TCamera);
var
  I, Count: LongInt;
begin
  ResetStats;
  Camera.SetAspect(FWidth / FHeight);
  FContext.ViewProj := Camera.ViewProj;
  FContext.View := Camera.View;
  FContext.Eye := Camera.Position;
  FContext.Camera := Camera;
  FContext.Ambient := Scene.Ambient;
  FContext.FogColor := Scene.FogColor;
  FContext.FogDensity := Scene.FogDensity;
  FContext.FogStart := Scene.FogStart;
  Count := 0;
  for I := 0 to Scene.LightCount - 1 do
    begin
      if Count >= MaxLights then Break;
      FContext.Lights[Count] := Scene.Lights[I];
      Inc(Count);
    end;
  FContext.LightCount := Count;
  ClearShadowSources;
  FDepthOnly := False;
  Clear(Scene.SkyColor, Scene.HorizonColor);
end;

procedure TRenderer.SetShadowSource(Index: LongInt; Light: TLight;
  const ViewProj: TMat4; Map: TShadowMap; Strength: Single);
begin
  if (Index < 0) or (Index >= MaxShadowMaps) then Exit;
  FContext.Shadows[Index].Active := True;
  FContext.Shadows[Index].Light := Light;
  FContext.Shadows[Index].ViewProj := ViewProj;
  FContext.Shadows[Index].Map := Map;
  FContext.Shadows[Index].Strength := Strength;
  if FContext.ShadowCount <= Index then
    FContext.ShadowCount := Index + 1;
end;

procedure TRenderer.ClearShadowSources;
var
  I: LongInt;
begin
  for I := 0 to MaxShadowMaps - 1 do
    begin
      FContext.Shadows[I].Active := False;
      FContext.Shadows[I].Light := nil;
    end;
  FContext.ShadowCount := 0;
end;

{ ------------------------------------------------------------- geometry --- }

function LerpClipVertex(const A, B: TClipVertex; T: Single): TClipVertex;
begin
  Result.Clip := Vec4Lerp(A.Clip, B.Clip, T);
  Result.World := Vec3Lerp(A.World, B.World, T);
  Result.Normal := Vec3Lerp(A.Normal, B.Normal, T);
  Result.UV := Vec2(LerpS(A.UV.X, B.UV.X, T), LerpS(A.UV.Y, B.UV.Y, T));
end;

procedure TRenderer.EmitTriangle(const A, B, C: TClipVertex; Mode: TRasterMode);
{ Clip against the near plane in clip space (z + w > 0) and rasterize the
  resulting polygon.  Clipping only against the near plane is all that is
  needed: the other five planes are handled by the scissor of the pixel
  bounding box, only the near plane can produce a vertex behind the eye. }
var
  DA, DB, DC: Single;
  Poly: array[0..7] of TClipVertex;
  N, I: LongInt;
begin
  DA := A.Clip.Z + A.Clip.W;
  DB := B.Clip.Z + B.Clip.W;
  DC := C.Clip.Z + C.Clip.W;
  if (DA <= 0) and (DB <= 0) and (DC <= 0) then Exit;
  if (DA > 0) and (DB > 0) and (DC > 0) then
    begin
      RasterizeTriangle(A, B, C, Mode);
      Exit;
    end;

  N := 0;
  if DA > 0 then
    begin
      Poly[N] := A;
      Inc(N);
    end;
  if (DA > 0) <> (DB > 0) then
    begin
      Poly[N] := LerpClipVertex(A, B, DA / (DA - DB));
      Inc(N);
    end;
  if DB > 0 then
    begin
      Poly[N] := B;
      Inc(N);
    end;
  if (DB > 0) <> (DC > 0) then
    begin
      Poly[N] := LerpClipVertex(B, C, DB / (DB - DC));
      Inc(N);
    end;
  if DC > 0 then
    begin
      Poly[N] := C;
      Inc(N);
    end;
  if (DC > 0) <> (DA > 0) then
    begin
      Poly[N] := LerpClipVertex(C, A, DC / (DC - DA));
      Inc(N);
    end;
  for I := 1 to N - 2 do
    RasterizeTriangle(Poly[0], Poly[I], Poly[I + 1], Mode);
end;

procedure TRenderer.RasterizeTriangle(const A, B, C: TClipVertex; Mode: TRasterMode);
var
  SX0, SY0, SX1, SY1, SX2, SY2: Single;
  IW0, IW1, IW2, Z0, Z1, Z2: Single;
  Area, InvArea: Single;
  MinX, MaxX, MinY, MaxY: LongInt;
  X, Y, Idx: LongInt;
  E0, E1, E2: Single;
  IX0, IX1, IX2, IY0, IY1, IY2: Single;
  RowE0, RowE1, RowE2: Single;
  B0, B1, B2, Z, NZ: Single;
  IW, InvIW, A0, A1, A2: Single;
  Front, DrawWire: Boolean;
  Len0, Len1, Len2, HalfWire: Single;
  Frag: TFragment;
  Color, WCol: TVec3;
  Alpha: Single;
begin
  // ---- viewport mapping (Y is flipped: NDC +Y is screen up) ----
  SX0 := (A.Clip.X / A.Clip.W * 0.5 + 0.5) * FWidth;
  SY0 := (0.5 - A.Clip.Y / A.Clip.W * 0.5) * FHeight;
  SX1 := (B.Clip.X / B.Clip.W * 0.5 + 0.5) * FWidth;
  SY1 := (0.5 - B.Clip.Y / B.Clip.W * 0.5) * FHeight;
  SX2 := (C.Clip.X / C.Clip.W * 0.5 + 0.5) * FWidth;
  SY2 := (0.5 - C.Clip.Y / C.Clip.W * 0.5) * FHeight;
  Z0 := A.Clip.Z / A.Clip.W;
  Z1 := B.Clip.Z / B.Clip.W;
  Z2 := C.Clip.Z / C.Clip.W;
  IW0 := 1 / A.Clip.W;
  IW1 := 1 / B.Clip.W;
  IW2 := 1 / C.Clip.W;

  // edge function of B->C evaluated at A gives the (doubled) screen area
  Area := (SX2 - SX1) * (SY0 - SY1) - (SY2 - SY1) * (SX0 - SX1);
  if Abs(Area) < 1E-9 then Exit;
  Front := Area < 0;                       // front faces wind CCW in NDC
  if Mode = rmColor then
    begin
      if (Settings.CullMode = cmBack) and (not Front) then Exit;
      if (Settings.CullMode = cmFront) and Front then Exit;
    end;
  InvArea := 1 / Area;

  MinX := Floor(MinS(SX0, MinS(SX1, SX2)) - 0.5);
  MaxX := Ceil(MaxS(SX0, MaxS(SX1, SX2)) - 0.5);
  MinY := Floor(MinS(SY0, MinS(SY1, SY2)) - 0.5);
  MaxY := Ceil(MaxS(SY0, MaxS(SY1, SY2)) - 0.5);
  if MinX < 0 then MinX := 0;
  if MinY < 0 then MinY := 0;
  if MaxX > FWidth - 1 then MaxX := FWidth - 1;
  if MaxY > FHeight - 1 then MaxY := FHeight - 1;
  if (MinX > MaxX) or (MinY > MaxY) then Exit;
  Inc(FStats.TrianglesDrawn);

  // per pixel increments of the three edge functions
  IX0 := SY1 - SY2;  IY0 := SX2 - SX1;
  IX1 := SY2 - SY0;  IY1 := SX0 - SX2;
  IX2 := SY0 - SY1;  IY2 := SX1 - SX0;

  RowE0 := (SX2 - SX1) * (MinY + 0.5 - SY1) - (SY2 - SY1) * (MinX + 0.5 - SX1);
  RowE1 := (SX0 - SX2) * (MinY + 0.5 - SY2) - (SY0 - SY2) * (MinX + 0.5 - SX2);
  RowE2 := (SX1 - SX0) * (MinY + 0.5 - SY0) - (SY1 - SY0) * (MinX + 0.5 - SX0);

  DrawWire := (Mode = rmColor) and (not FDepthOnly) and Settings.Wireframe;
  if DrawWire then
    begin
      HalfWire := Settings.WireWidth * 0.5;
      Len0 := Sqrt(Sqr(SX2 - SX1) + Sqr(SY2 - SY1));
      Len1 := Sqrt(Sqr(SX0 - SX2) + Sqr(SY0 - SY2));
      Len2 := Sqrt(Sqr(SX1 - SX0) + Sqr(SY1 - SY0));
      WCol := Settings.WireColor;
    end
  else
    begin
      HalfWire := 0;
      Len0 := 1;
      Len1 := 1;
      Len2 := 1;
      WCol := Vec3Zero;
    end;

  Frag.Material := FCurMaterial;
  Frag.Node := FCurNode;
  Frag.Triangle := FTriIndex;
  Frag.Color := Vec3One;
  if FCurMaterial <> nil then
    Frag.Color := FCurMaterial.Color;

  Idx := MinY * FWidth + MinX;
  for Y := MinY to MaxY do
    begin
      E0 := RowE0;
      E1 := RowE1;
      E2 := RowE2;
      for X := MinX to MaxX do
        begin
          if (E0 >= 0) and (E1 >= 0) and (E2 >= 0) then
            begin
              B0 := E0 * InvArea;
              B1 := E1 * InvArea;
              B2 := E2 * InvArea;
              Z := B0 * Z0 + B1 * Z1 + B2 * Z2;
              NZ := Z * 0.5 + 0.5;                 // depth buffer range [0,1]
              if (not Settings.DepthTest) or (NZ < FDepth[Idx]) then
                begin
                  if Settings.DepthWrite then
                    FDepth[Idx] := NZ;
                  if not FDepthOnly then
                    begin
                      IW := B0 * IW0 + B1 * IW1 + B2 * IW2;
                      if IW > 1E-20 then
                        begin
                          if Settings.PerspectiveCorrect then
                            begin
                              InvIW := 1 / IW;
                              A0 := B0 * IW0 * InvIW;
                              A1 := B1 * IW1 * InvIW;
                              A2 := B2 * IW2 * InvIW;
                            end
                          else
                            begin
                              A0 := B0;
                              A1 := B1;
                              A2 := B2;
                              InvIW := 1;
                            end;
                          Frag.World := Vec3(A0 * A.World.X + A1 * B.World.X + A2 * C.World.X,
                                             A0 * A.World.Y + A1 * B.World.Y + A2 * C.World.Y,
                                             A0 * A.World.Z + A1 * B.World.Z + A2 * C.World.Z);
                          Frag.Normal := Vec3(A0 * A.Normal.X + A1 * B.Normal.X + A2 * C.Normal.X,
                                              A0 * A.Normal.Y + A1 * B.Normal.Y + A2 * C.Normal.Y,
                                              A0 * A.Normal.Z + A1 * B.Normal.Z + A2 * C.Normal.Z);
                          Frag.UV := Vec2(A0 * A.UV.X + A1 * B.UV.X + A2 * C.UV.X,
                                          A0 * A.UV.Y + A1 * B.UV.Y + A2 * C.UV.Y);
                          Frag.Depth := InvIW;      // eye space distance
                          Frag.ScreenX := X;
                          Frag.ScreenY := Y;

                          if (FCurMaterial <> nil) and (FCurMaterial.Alpha < 1) then
                            Alpha := FCurMaterial.Alpha
                          else
                            Alpha := 1;

                          if DrawWire and
                             ((Abs(E0) / Len0 <= HalfWire) or
                              (Abs(E1) / Len1 <= HalfWire) or
                              (Abs(E2) / Len2 <= HalfWire)) then
                            Color := Vec3Lerp(WCol, Frag.Color, 0.15)
                          else if Settings.Fill or FDepthOnly then
                            begin
                              Inc(FStats.PixelsShaded);
                              if OnFragment <> nil then
                                Color := OnFragment(Frag)
                              else
                                Color := ShadeDefault(Frag);
                            end
                          else
                            Color := Frag.Color;

                          if Alpha < 1 then
                            Color := Vec3Lerp(FColor[Idx], Color, Alpha);
                          FColor[Idx] := Color;
                        end;
                    end;
                end;
            end;
          E0 := E0 + IX0;
          E1 := E1 + IX1;
          E2 := E2 + IX2;
          Inc(Idx);
        end;
      RowE0 := RowE0 + IY0;
      RowE1 := RowE1 + IY1;
      RowE2 := RowE2 + IY2;
      Inc(Idx, FWidth - (MaxX - MinX + 1));
    end;
end;

procedure TRenderer.DrawMeshInternal(const Mesh: TMesh; const Model: TMat4;
  Mat: TMaterial; Node: TNode; const ViewProj: TMat4; Mode: TRasterMode);
var
  T, I0, I1, I2, V: LongInt;
  MVP, NM: TMat4;
  A, B, C: TClipVertex;
  C4: TVec4;
  P: TVec3;

  procedure SetupVertex(const Src: TVec3; const SrcN: TVec3; const SrcUV: TVec2;
    out Dst: TClipVertex);
  begin
    Dst.Clip := Mat4MulPoint4(MVP, Src);
    Dst.World := Mat4MulPoint(Model, Src);
    Dst.Normal := Mat4MulDir(NM, SrcN);
    Dst.UV := SrcUV;
  end;

begin
  if (Mesh = nil) or (Mesh.TriangleCount = 0) then Exit;
  MVP := ViewProj * Model;
  NM := Mat4NormalMatrix(Model);
  FCurNode := Node;
  FCurMaterial := Mat;
  for T := 0 to Mesh.TriangleCount - 1 do
    begin
      I0 := Mesh.Indices[T * 3];
      I1 := Mesh.Indices[T * 3 + 1];
      I2 := Mesh.Indices[T * 3 + 2];
      SetupVertex(Mesh.Positions[I0], Mesh.Normals[I0], Mesh.UVs[I0], A);
      SetupVertex(Mesh.Positions[I1], Mesh.Normals[I1], Mesh.UVs[I1], B);
      SetupVertex(Mesh.Positions[I2], Mesh.Normals[I2], Mesh.UVs[I2], C);
      FTriIndex := T;
      Inc(FStats.TrianglesSubmitted);
      EmitTriangle(A, B, C, Mode);
    end;

  if (Mode = rmColor) and (not FDepthOnly) and Settings.Points then
    for V := 0 to Mesh.VertexCount - 1 do
      begin
        P := Mat4MulPoint(Model, Mesh.Positions[V]);
        C4 := Mat4MulPoint4(ViewProj, P);
        if C4.W <= 1E-5 then Continue;
        DrawPoint3D(P, Settings.PointColor);
      end;
end;

procedure TRenderer.DrawMesh(const Mesh: TMesh; const Model: TMat4; Mat: TMaterial);
begin
  DrawMeshInternal(Mesh, Model, Mat, nil, FContext.ViewProj, rmColor);
end;

procedure TRenderer.DrawNode(N: TNode);
begin
  if (N = nil) or (N.Mesh = nil) or (not N.Visible) then Exit;
  Inc(FStats.NodesDrawn);
  DrawMeshInternal(N.Mesh, N.World, N.Material, N, FContext.ViewProj, rmColor);
end;

procedure TRenderer.DrawScene(Scene: TScene);
var
  I: LongInt;
  N: TNode;
  F: TFrustum;
begin
  if Scene = nil then Exit;
  F := FrustumFromViewProj(FContext.ViewProj);
  for I := 0 to Scene.NodeCount - 1 do
    begin
      N := Scene.Nodes[I];
      if (not N.Visible) or (N.Mesh = nil) then Continue;
      if not FrustumTestAABB(F, N.BBoxWorld) then
        begin
          Inc(FStats.NodesCulled);
          Continue;
        end;
      Inc(FStats.NodesDrawn);
      DrawMeshInternal(N.Mesh, N.World, N.Material, N, FContext.ViewProj, rmColor);
    end;
end;

procedure TRenderer.RenderDepthOnly(Scene: TScene; const ViewProj: TMat4;
  Map: TShadowMap; const Cull: TCullMode; DepthBias: Single);
var
  I, J, K: LongInt;
  N: TNode;
  OldDepth: array of Single;
begin
  if (Scene = nil) or (Map = nil) then Exit;
  // swap the framebuffer depth buffer for the shadow map one (reference
  // swap, no data is copied) and rasterize depth only
  OldDepth := FDepth;
  if Length(FDepthSwap) <> Map.Size * Map.Size then
    SetLength(FDepthSwap, Map.Size * Map.Size);
  FDepth := FDepthSwap;
  for J := 0 to High(FDepth) do
    FDepth[J] := 1;

  FDepthOnly := True;
  K := Ord(Settings.CullMode);
  Settings.CullMode := Cull;
  for I := 0 to Scene.NodeCount - 1 do
    begin
      N := Scene.Nodes[I];
      if (not N.Visible) or (N.Mesh = nil) or (not N.CastShadow) then Continue;
      DrawMeshInternal(N.Mesh, N.World, N.Material, N, ViewProj, rmDepth);
    end;
  Settings.CullMode := TCullMode(K);
  FDepthOnly := False;

  { Copy the rendered depths into the map.  A positive DepthBias pushes the
    stored depth away from the light, which reduces shadow acne at the cost
    of a little peter-panning. }
  for J := 0 to Map.Size - 1 do
    for I := 0 to Map.Size - 1 do
      Map.SetDepth(I, J, ClampS(FDepth[J * Map.Size + I] + DepthBias, 0, 1));

  FDepthSwap := FDepth;
  FDepth := OldDepth;
end;

{ --------------------------------------------------------------- 2D/3D ----- }

function TRenderer.ProjectPoint(const P: TVec3; out X, Y: LongInt; out Depth: Single): Boolean;
var
  C: TVec4;
begin
  C := Mat4MulPoint4(FContext.ViewProj, P);
  Result := C.W > 1E-5;
  if not Result then
    begin
      X := 0;
      Y := 0;
      Depth := 0;
      Exit;
    end;
  X := Floor((C.X / C.W * 0.5 + 0.5) * FWidth);
  Y := Floor((0.5 - C.Y / C.W * 0.5) * FHeight);
  Depth := C.Z / C.W * 0.5 + 0.5;   // depth buffer value
end;

procedure TRenderer.DrawPoint3D(const P: TVec3; const Color: TVec3);
var
  X, Y: LongInt;
  D: Single;
  Idx: LongInt;
begin
  if not ProjectPoint(P, X, Y, D) then Exit;
  if (X < 0) or (X >= FWidth) or (Y < 0) or (Y >= FHeight) then Exit;
  Idx := Y * FWidth + X;
  if Settings.DepthTest and (D > FDepth[Idx]) then Exit;
  FColor[Idx] := Color;
end;

procedure TRenderer.DrawLine3D(const A, B: TVec3; const Color: TVec3);
var
  X0, Y0, X1, Y1: LongInt;
  D0, D1, D, T: Single;
  Steps, I: LongInt;
  X, Y, Idx: LongInt;
begin
  if (not ProjectPoint(A, X0, Y0, D0)) or (not ProjectPoint(B, X1, Y1, D1)) then Exit;
  Steps := Max(Abs(X1 - X0), Abs(Y1 - Y0));
  if Steps <= 0 then
    begin
      SetPixelSafe(X0, Y0, Color);
      Exit;
    end;
  if Steps > 4 * FWidth then Steps := 4 * FWidth;
  for I := 0 to Steps do
    begin
      T := I / Steps;
      X := Round(X0 + (X1 - X0) * T);
      Y := Round(Y0 + (Y1 - Y0) * T);
      D := D0 + (D1 - D0) * T;
      if (X < 0) or (X >= FWidth) or (Y < 0) or (Y >= FHeight) then Continue;
      Idx := Y * FWidth + X;
      FColor[Idx] := Color;
    end;
end;

end.
