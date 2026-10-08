{ ============================================================================
  ucamera.pas  --  камера

  Чистая математика без единого вызова OpenGL: матрицы вида и проекции
  плюс пирамида видимости. Вынесено отдельно, чтобы покрывать тестами
  и использовать в программном растеризаторе.
  ============================================================================ }
unit ucamera;

{$MODE OBJFPC}
{$H+}

interface

uses
  umath;

type
  TCamera = record
    pos      : TVec3;
    yaw, pitch: Single;
    fov      : Single;
    znear, zfar: Single;
    aspect   : Single;
    view, proj, viewproj: TMat4;
    frustum  : TFrustum;
    forward_ : TVec3;
    right    : TVec3;
    up       : TVec3;
  end;

procedure camera_init(var c: TCamera; const pos: TVec3);
procedure camera_update(var c: TCamera; width, height: Integer);
procedure camera_move(var c: TCamera; const localDelta: TVec3);

implementation

{ =========================================================================
  Камера
  ========================================================================= }

procedure camera_init(var c: TCamera; const pos: TVec3);
begin
  FillChar(c, SizeOf(c), 0);
  c.pos := pos;
  c.yaw := -PI_F * 0.5;
  c.pitch := -0.2;
  c.fov := 70.0 * DEG2RAD;
  c.znear := 0.05;
  c.zfar := 500.0;
  c.aspect := 16.0 / 9.0;
end;

procedure camera_update(var c: TCamera; width, height: Integer);
var
  cp, sp: Single;
begin
  if height < 1 then height := 1;
  c.aspect := width / height;
  c.pitch := fclamp(c.pitch, -1.553, 1.553);

  cp := Cos(c.pitch); sp := Sin(c.pitch);
  c.forward_ := v3_norm(v3(Cos(c.yaw) * cp, sp, Sin(c.yaw) * cp));
  c.right := v3_norm(v3_cross(c.forward_, v3(0, 1, 0)));
  c.up := v3_cross(c.right, c.forward_);

  c.view := m4_lookat(c.pos, v3_add(c.pos, c.forward_), v3(0, 1, 0));
  c.proj := m4_perspective(c.fov, c.aspect, c.znear, c.zfar);
  c.viewproj := m4_mul(c.proj, c.view);
  c.frustum := frustum_from_matrix(c.viewproj);
end;

procedure camera_move(var c: TCamera; const localDelta: TVec3);
begin
  c.pos := v3_add(c.pos,
    v3_add(v3_mul(c.right, localDelta.x),
    v3_add(v3_mul(v3(0, 1, 0), localDelta.y),
           v3_mul(c.forward_, localDelta.z))));
end;


end.
