{ ============================================================================
  hdeh-scene - cameras, lights, materials, scene nodes.

  Ownership rules (kept simple on purpose):

    * TScene owns its TNode and TLight objects.
    * A TNode owns its TMaterial.
    * Meshes and textures are NOT owned by anything in the scene - the
      application creates them once and may share them between nodes.

  Node transformations are limited to translation / rotation / (non uniform)
  scale.  The rotation is applied as Z * Y * X (yaw, then pitch, then roll),
  which is enough for the kind of scenes this engine targets and keeps the
  API obvious.  If you need anything else, build the mesh with
  TMesh.Transform or set Node.Local directly.
  ============================================================================ }
unit hdeh_scene;
{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, hdeh_math, hdeh_mesh, hdeh_image;

type
  TShadingModel = (smUnlit, smFlat, smPhong);
  TLightKind = (lkDirectional, lkPoint, lkSpot);

  TMaterial = class
  public
    Name: string;
    Color: TVec3;              // linear albedo
    Specular: Single;          // 0 .. 1, strength of the highlight
    Shininess: Single;         // specular exponent (8 = broad, 128 = tight)
    Emissive: Single;          // added after lighting, 0 .. 1
    Alpha: Single;             // 1 = opaque; < 1 blends over the framebuffer
    Shading: TShadingModel;
    DoubleSided: Boolean;
    Texture: TImage;           // optional diffuse texture (not owned)
    TextureScale: Single;      // world units per texture repeat
    NormalMap: TImage;         // optional normal map (not owned)
    NormalStrength: Single;
    constructor Create;
    class function Make(const AColor: TVec3): TMaterial;
    class function MakeGlossy(const AColor: TVec3; ASpecular, AShininess: Single): TMaterial;
    procedure SetTexture(Tex: TImage; Scale: Single);
    procedure SetNormalMap(Tex: TImage; Strength: Single);
  end;

  TLight = class
  public
    Name: string;
    Kind: TLightKind;
    Position: TVec3;
    Direction: TVec3;          // direction the light points at (normalized)
    Color: TVec3;              // linear colour
    Intensity: Single;
    Range: Single;             // point/spot falloff distance
    InnerAngle: Single;        // spot cone, degrees
    OuterAngle: Single;        // spot cone with penumbra, degrees
    CastShadow: Boolean;
    constructor Create(K: TLightKind; const AColor: TVec3; AIntensity: Single);
    procedure SetDirection(const D: TVec3);
    function IsShadowCaster: Boolean;
  end;

  TNode = class
  public
    Name: string;
    Mesh: TMesh;               // not owned
    Material: TMaterial;       // owned
    Position, Rotation, Scale: TVec3;
    Visible: Boolean;
    CastShadow: Boolean;
    ReceiveShadow: Boolean;
    Local: TMat4;
    World: TMat4;
    constructor Create(AMesh: TMesh; AMaterial: TMaterial);
    destructor Destroy; override;
    procedure UpdateLocal;
    function BBoxWorld: TAABB;
  end;

  TCamera = class
  public
    Position, Target, Up: TVec3;
    FovY: Single;              // vertical field of view, degrees
    ZNear, ZFar: Single;
    Aspect: Single;
    constructor Create;
    procedure SetAspect(A: Single);
    function View: TMat4;
    function Proj: TMat4;
    function ViewProj: TMat4;
    function Forward: TVec3;
    function Right: TVec3;
    function UpVector: TVec3;
    function Frustum: TFrustum;
    function EyePosition: TVec3;
  end;

  TScene = class
  private
    FNodes: TFPList;
    FLights: TFPList;
    function GetNode(I: LongInt): TNode;
    function GetLight(I: LongInt): TLight;
  public
    Name: string;
    Ambient: TVec3;            // ambient light colour
    SkyColor: TVec3;           // background gradient, top
    HorizonColor: TVec3;       // background gradient, bottom
    FogColor: TVec3;
    FogDensity: Single;        // 0 disables fog, exp(-(d*density)^2) falloff
    FogStart: Single;

    constructor Create;
    destructor Destroy; override;

    function AddNode(Mesh: TMesh; Material: TMaterial): TNode;
    function AddLight(L: TLight): TLight;
    function AddDirectionalLight(const Dir, Color: TVec3; Intensity: Single): TLight;
    function AddPointLight(const Pos, Color: TVec3; Intensity, Range: Single): TLight;
    function AddSpotLight(const Pos, Dir, Color: TVec3; Intensity, Range,
                          InnerAngle, OuterAngle: Single): TLight;
    procedure Clear;
    procedure UpdateTransforms;
    function BBox: TAABB;
    function OrderLightsByDistance(const Eye: TVec3): LongInt;  // returns count

    property Nodes[I: LongInt]: TNode read GetNode;
    property Lights[I: LongInt]: TLight read GetLight;
    function NodeCount: LongInt; inline;
    function LightCount: LongInt; inline;
  end;

{ Convenience: attach a mesh with a simple diffuse material in one line. }
function SceneAddMesh(Scene: TScene; Mesh: TMesh; const Color: TVec3): TNode;

implementation

{ ============================================================== material === }

constructor TMaterial.Create;
begin
  inherited Create;
  Name := '';
  Color := Vec3(0.8, 0.8, 0.8);
  Specular := 0.25;
  Shininess := 32;
  Emissive := 0;
  Alpha := 1;
  Shading := smPhong;
  DoubleSided := False;
  Texture := nil;
  TextureScale := 1;
  NormalMap := nil;
  NormalStrength := 1;
end;

class function TMaterial.Make(const AColor: TVec3): TMaterial;
begin
  Result := TMaterial.Create;
  Result.Color := AColor;
end;

class function TMaterial.MakeGlossy(const AColor: TVec3; ASpecular,
  AShininess: Single): TMaterial;
begin
  Result := TMaterial.Create;
  Result.Color := AColor;
  Result.Specular := ASpecular;
  Result.Shininess := AShininess;
end;

procedure TMaterial.SetTexture(Tex: TImage; Scale: Single);
begin
  Texture := Tex;
  TextureScale := Scale;
end;

procedure TMaterial.SetNormalMap(Tex: TImage; Strength: Single);
begin
  NormalMap := Tex;
  NormalStrength := Strength;
end;

{ ================================================================= light === }

constructor TLight.Create(K: TLightKind; const AColor: TVec3; AIntensity: Single);
begin
  inherited Create;
  Kind := K;
  Position := Vec3Zero;
  Direction := Vec3(0, -1, 0);
  Color := AColor;
  Intensity := AIntensity;
  Range := 20;
  InnerAngle := 20;
  OuterAngle := 30;
  CastShadow := False;
end;

procedure TLight.SetDirection(const D: TVec3);
begin
  Direction := Vec3Normalize(D);
end;

function TLight.IsShadowCaster: Boolean;
begin
  Result := CastShadow and (Kind <> lkPoint);
end;

{ ================================================================== node === }

constructor TNode.Create(AMesh: TMesh; AMaterial: TMaterial);
begin
  inherited Create;
  Mesh := AMesh;
  Material := AMaterial;
  Position := Vec3Zero;
  Rotation := Vec3Zero;
  Scale := Vec3One;
  Visible := True;
  CastShadow := True;
  ReceiveShadow := True;
  UpdateLocal;
  World := Local;
end;

destructor TNode.Destroy;
begin
  FreeAndNil(Material);
  inherited Destroy;
end;

procedure TNode.UpdateLocal;
begin
  Local := Mat4Compose(Position, Rotation, Scale);
  World := Local;
end;

function TNode.BBoxWorld: TAABB;
begin
  if Mesh = nil then
    Result := AABBEmpty
  else
    Result := AABBTransform(Mesh.Bounds, World);
end;

{ ================================================================ camera === }

constructor TCamera.Create;
begin
  inherited Create;
  Position := Vec3(0, 3, 8);
  Target := Vec3Zero;
  Up := Vec3UnitY;
  FovY := 60;
  ZNear := 0.2;
  ZFar := 200;
  Aspect := 4 / 3;
end;

procedure TCamera.SetAspect(A: Single);
begin
  if A > 0.01 then Aspect := A;
end;

function TCamera.View: TMat4;
begin
  Result := Mat4LookAt(Position, Target, Up);
end;

function TCamera.Proj: TMat4;
begin
  Result := Mat4Perspective(FovY, Aspect, ZNear, ZFar);
end;

function TCamera.ViewProj: TMat4;
begin
  Result := Proj * View;
end;

function TCamera.Forward: TVec3;
begin
  Result := Vec3Normalize(Vec3Sub(Target, Position));
end;

function TCamera.Right: TVec3;
begin
  Result := Vec3Normalize(Vec3Cross(Forward, Up));
end;

function TCamera.UpVector: TVec3;
begin
  Result := Vec3Cross(Right, Forward);
end;

function TCamera.Frustum: TFrustum;
begin
  Result := FrustumFromViewProj(ViewProj);
end;

function TCamera.EyePosition: TVec3;
begin
  Result := Position;
end;

{ ================================================================= scene === }

constructor TScene.Create;
begin
  inherited Create;
  FNodes := TFPList.Create;
  FLights := TFPList.Create;
  Name := '';
  Ambient := Vec3(0.12, 0.13, 0.16);
  SkyColor := Vec3(0.10, 0.14, 0.22);
  HorizonColor := Vec3(0.28, 0.30, 0.36);
  FogColor := Vec3(0.20, 0.23, 0.30);
  FogDensity := 0;
  FogStart := 0;
end;

destructor TScene.Destroy;
begin
  Clear;
  FreeAndNil(FNodes);
  FreeAndNil(FLights);
  inherited Destroy;
end;

procedure TScene.Clear;
var
  I: LongInt;
begin
  for I := 0 to FNodes.Count - 1 do
    TNode(FNodes[I]).Free;
  FNodes.Clear;
  for I := 0 to FLights.Count - 1 do
    TLight(FLights[I]).Free;
  FLights.Clear;
end;

function TScene.AddNode(Mesh: TMesh; Material: TMaterial): TNode;
begin
  Result := TNode.Create(Mesh, Material);
  FNodes.Add(Result);
  Result.UpdateLocal;
end;

function TScene.AddLight(L: TLight): TLight;
begin
  FLights.Add(L);
  Result := L;
end;

function TScene.AddDirectionalLight(const Dir, Color: TVec3; Intensity: Single): TLight;
begin
  Result := AddLight(TLight.Create(lkDirectional, Color, Intensity));
  Result.SetDirection(Dir);
end;

function TScene.AddPointLight(const Pos, Color: TVec3; Intensity, Range: Single): TLight;
begin
  Result := AddLight(TLight.Create(lkPoint, Color, Intensity));
  Result.Position := Pos;
  Result.Range := Range;
end;

function TScene.AddSpotLight(const Pos, Dir, Color: TVec3; Intensity, Range,
  InnerAngle, OuterAngle: Single): TLight;
begin
  Result := AddLight(TLight.Create(lkSpot, Color, Intensity));
  Result.Position := Pos;
  Result.SetDirection(Dir);
  Result.Range := Range;
  Result.InnerAngle := InnerAngle;
  Result.OuterAngle := OuterAngle;
end;

procedure TScene.UpdateTransforms;
var
  I: LongInt;
  N: TNode;
begin
  for I := 0 to FNodes.Count - 1 do
    begin
      N := TNode(FNodes[I]);
      N.UpdateLocal;
    end;
end;

function TScene.BBox: TAABB;
var
  I: LongInt;
begin
  Result := AABBEmpty;
  for I := 0 to FNodes.Count - 1 do
    with TNode(FNodes[I]) do
      if Visible and (Mesh <> nil) then
        Result := AABBUnion(Result, AABBTransform(Mesh.Bounds, World));
end;

function TScene.OrderLightsByDistance(const Eye: TVec3): LongInt;
{ simple insertion sort of the shadow casting order: near lights first so
  that the shadow map limit keeps the visually important ones }
var
  I, J: LongInt;
  L1, L2: TLight;
  D1, D2: Single;
begin
  for I := 1 to FLights.Count - 1 do
    begin
      L1 := TLight(FLights[I]);
      if L1.Kind = lkDirectional then Continue;
      D1 := Vec3DistanceSq(L1.Position, Eye);
      J := I - 1;
      while J >= 0 do
        begin
          L2 := TLight(FLights[J]);
          if L2.Kind = lkDirectional then Break;
          D2 := Vec3DistanceSq(L2.Position, Eye);
          if D2 <= D1 then Break;
          FLights.Exchange(J, J + 1);
          Dec(J);
        end;
    end;
  Result := FLights.Count;
end;

function TScene.NodeCount: LongInt;
begin
  Result := FNodes.Count;
end;

function TScene.LightCount: LongInt;
begin
  Result := FLights.Count;
end;

function TScene.GetNode(I: LongInt): TNode;
begin
  Result := TNode(FNodes[I]);
end;

function TScene.GetLight(I: LongInt): TLight;
begin
  Result := TLight(FLights[I]);
end;

function SceneAddMesh(Scene: TScene; Mesh: TMesh; const Color: TVec3): TNode;
begin
  Result := Scene.AddNode(Mesh, TMaterial.Make(Color));
end;

end.
