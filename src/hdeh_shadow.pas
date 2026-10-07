{ ============================================================================
  hdeh-shadow - shadow maps for directional and spot lights.

  A shadow map is just a depth buffer rendered from the point of view of a
  light; while shading a fragment the engine projects the fragment into that
  light space and compares its depth with the depth stored in the map.  The
  lookup uses 3x3 percentage closer filtering, so the shadow edges are soft
  even though the maps are small.

  Point lights are not supported on purpose: a correct point light shadow
  needs a cube map (six passes), which does not fit the "simple engine"
  budget.  Use a spot light instead - it is what you want most of the time,
  and its shadows are sharper.
  ============================================================================ }
unit hdeh_shadow;
{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math, hdeh_math, hdeh_mesh, hdeh_scene, hdeh_raster;

{ Orthographic light matrix that covers the whole scene bounding box. }
function DirectionalShadowMatrix(Light: TLight; const Box: TAABB): TMat4;

{ Perspective light matrix for a spot light cone. }
function SpotShadowMatrix(Light: TLight): TMat4;

{ Renders a depth map for every shadow casting light of the scene and binds
  them to the renderer.  Returns the number of maps rendered.  Call this
  after Renderer.BeginFrame and before Renderer.DrawScene. }
function ShadowPasses(Renderer: TRenderer; Scene: TScene; const Box: TAABB;
  Cull: TCullMode = cmNone): LongInt;

implementation

function DirectionalShadowMatrix(Light: TLight; const Box: TAABB): TMat4;
var
  Center, Eye, Up, Dir: TVec3;
  Radius: Single;
begin
  Result := Mat4Identity;
  if not Box.Valid then Exit;
  Center := AABBCenter(Box);
  Radius := AABBRadius(Box);
  if Radius < 0.5 then Radius := 0.5;
  Dir := Vec3Normalize(Light.Direction);
  if Vec3LengthSq(Dir) < 0.5 then Dir := Vec3(0, -1, 0);
  Up := Vec3UnitY;
  if Abs(Vec3Dot(Dir, Up)) > 0.95 then Up := Vec3UnitX;
  Eye := Vec3Sub(Center, Vec3Scale(Dir, Radius * 2));
  Result := Mat4Ortho(-Radius, Radius, -Radius, Radius, 0.01, Radius * 4) *
            Mat4LookAt(Eye, Center, Up);
end;

function SpotShadowMatrix(Light: TLight): TMat4;
var
  Dir, Up, Target: TVec3;
  Fov: Single;
begin
  Dir := Vec3Normalize(Light.Direction);
  if Vec3LengthSq(Dir) < 0.5 then Dir := Vec3(0, -1, 0);
  Target := Vec3Add(Light.Position, Dir);
  Up := Vec3UnitY;
  if Abs(Vec3Dot(Dir, Up)) > 0.95 then Up := Vec3UnitZ;
  Fov := ClampS(Light.OuterAngle * 2.2, 1, 170);
  Result := Mat4Perspective(Fov, 1, 0.05, MaxS(Light.Range * 2, 1)) *
            Mat4LookAt(Light.Position, Target, Up);
end;

function ShadowPasses(Renderer: TRenderer; Scene: TScene; const Box: TAABB;
  Cull: TCullMode): LongInt;
var
  I, Index: LongInt;
  L: TLight;
  VP: TMat4;
  B: TAABB;
begin
  Result := 0;
  if (Renderer = nil) or (Scene = nil) then Exit;
  if not Renderer.Settings.Shadows then Exit;
  B := Box;
  if not B.Valid then B := Scene.BBox;
  if not B.Valid then Exit;
  Index := 0;
  for I := 0 to Scene.LightCount - 1 do
    begin
      if Index >= MaxShadowMaps then Break;
      L := Scene.Lights[I];
      if not L.IsShadowCaster then Continue;
      case L.Kind of
        lkDirectional: VP := DirectionalShadowMatrix(L, B);
        lkSpot: VP := SpotShadowMatrix(L);
      else
        Continue;
      end;
      Renderer.RenderDepthOnly(Scene, VP, Renderer.ShadowMap(Index), Cull, 0);
      Renderer.SetShadowSource(Index, L, VP, Renderer.ShadowMap(Index), 1);
      Inc(Index);
      Inc(Result);
    end;
end;

end.
