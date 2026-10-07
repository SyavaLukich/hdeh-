{ ============================================================================
  umesh.pas  --  геометрия и буферы видеокарты

  Один меш = один VAO + вершинный буфер + индексный буфер + (опционально)
  буфер экземпляров. Никаких классов: меш -- это запись, которую можно
  копировать и держать в массиве.

  Вершина занимает ровно 32 байта (позиция, нормаль, UV) -- половина строки
  кэша, выровнено, видеокарте удобно.
  ============================================================================ }
unit umesh;

{$MODE OBJFPC}
{$H+}
{$INLINE ON}

interface

uses
  umath, ugl;

type
  TVertex = record
    px, py, pz: Single;
    nx, ny, nz: Single;
    u, v      : Single;
  end;
  PVertex = ^TVertex;

  { Данные одного экземпляра для инстансной отрисовки: матрица модели
    и цвет. 80 байт, обновляются одним glBufferSubData на кадр. }
  TInstance = record
    model: TMat4;
    color: TVec4;
  end;
  PInstance = ^TInstance;

  TMesh = record
    vao, vbo, ibo, ivbo: GLuint;
    nverts, nidx       : Integer;
    maxInstances       : Integer;
    bounds             : TAABB;
    radius             : Single;
  end;
  PMesh = ^TMesh;

  TVertexArray = array of TVertex;
  TIndexArray  = array of Cardinal;

{ Загрузка готовых массивов в видеопамять. }
function  mesh_upload(const verts: TVertexArray; const idx: TIndexArray): TMesh;
procedure mesh_enable_instancing(var m: TMesh; maxInstances: Integer);
procedure mesh_update_instances(var m: TMesh; const inst: array of TInstance;
                                count: Integer);
procedure mesh_draw(const m: TMesh);
procedure mesh_draw_instanced(const m: TMesh; count: Integer);
procedure mesh_free(var m: TMesh);

{ --- генераторы примитивов --- }
function  mesh_make_box(const half: TVec3): TMesh;
function  mesh_make_sphere(r: Single; segs, rings: Integer): TMesh;
function  mesh_make_plane(size: Single; tiles: Integer): TMesh;
function  mesh_make_capsule(r, halfheight: Single; segs, rings: Integer): TMesh;

{ Вершины бокса как набор точек для выпуклой оболочки физики. }
procedure box_hull_points(const half: TVec3; out pts: array of TVec3);

implementation

function mesh_upload(const verts: TVertexArray; const idx: TIndexArray): TMesh;
var
  i: Integer;
  p: TVec3;
  d: Single;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.nverts := Length(verts);
  Result.nidx := Length(idx);

  glGenVertexArrays(1, @Result.vao);
  glBindVertexArray(Result.vao);

  glGenBuffers(1, @Result.vbo);
  glBindBuffer(GL_ARRAY_BUFFER, Result.vbo);
  glBufferData(GL_ARRAY_BUFFER, Result.nverts * SizeOf(TVertex),
               @verts[0], GL_STATIC_DRAW);

  { atr 0: позиция, atr 1: нормаль, atr 2: текстурные координаты }
  glEnableVertexAttribArray(0);
  glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, SizeOf(TVertex), Pointer(0));
  glEnableVertexAttribArray(1);
  glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, SizeOf(TVertex), Pointer(12));
  glEnableVertexAttribArray(2);
  glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, SizeOf(TVertex), Pointer(24));

  glGenBuffers(1, @Result.ibo);
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, Result.ibo);
  glBufferData(GL_ELEMENT_ARRAY_BUFFER, Result.nidx * SizeOf(Cardinal),
               @idx[0], GL_STATIC_DRAW);

  glBindVertexArray(0);

  { Границы считаем сразу -- они нужны отсечению по пирамиде видимости. }
  Result.bounds := aabb_empty;
  Result.radius := 0;
  for i := 0 to Result.nverts - 1 do
  begin
    p := v3(verts[i].px, verts[i].py, verts[i].pz);
    aabb_add(Result.bounds, p);
    d := v3_lensq(p);
    if d > Result.radius then Result.radius := d;
  end;
  Result.radius := Sqrt(Result.radius);
end;

procedure mesh_enable_instancing(var m: TMesh; maxInstances: Integer);
var
  i: Integer;
  ofs: PtrInt;
begin
  m.maxInstances := maxInstances;
  glBindVertexArray(m.vao);
  glGenBuffers(1, @m.ivbo);
  glBindBuffer(GL_ARRAY_BUFFER, m.ivbo);
  { GL_STREAM_DRAW: драйвер знает, что буфер переписывается каждый кадр. }
  glBufferData(GL_ARRAY_BUFFER, maxInstances * SizeOf(TInstance), nil,
               GL_STREAM_DRAW);

  { Матрица 4x4 занимает четыре слота атрибутов: 3, 4, 5, 6. }
  for i := 0 to 3 do
  begin
    ofs := i * 16;
    glEnableVertexAttribArray(3 + i);
    glVertexAttribPointer(3 + i, 4, GL_FLOAT, GL_FALSE, SizeOf(TInstance),
                          Pointer(ofs));
    glVertexAttribDivisor(3 + i, 1);
  end;
  { Цвет экземпляра -- слот 7. }
  glEnableVertexAttribArray(7);
  glVertexAttribPointer(7, 4, GL_FLOAT, GL_FALSE, SizeOf(TInstance),
                        Pointer(64));
  glVertexAttribDivisor(7, 1);

  glBindVertexArray(0);
end;

procedure mesh_update_instances(var m: TMesh; const inst: array of TInstance;
                                count: Integer);
begin
  if (count <= 0) or (m.ivbo = 0) then Exit;
  if count > m.maxInstances then count := m.maxInstances;
  glBindBuffer(GL_ARRAY_BUFFER, m.ivbo);
  { Сначала "осиротим" буфер: драйвер выдаст свежую память и не будет
    ждать, пока видеокарта дорисует прошлый кадр. }
  glBufferData(GL_ARRAY_BUFFER, m.maxInstances * SizeOf(TInstance), nil,
               GL_STREAM_DRAW);
  glBufferSubData(GL_ARRAY_BUFFER, 0, count * SizeOf(TInstance), @inst[0]);
end;

procedure mesh_draw(const m: TMesh);
begin
  glBindVertexArray(m.vao);
  glDrawElements(GL_TRIANGLES, m.nidx, GL_UNSIGNED_INT, nil);
end;

procedure mesh_draw_instanced(const m: TMesh; count: Integer);
begin
  if count <= 0 then Exit;
  glBindVertexArray(m.vao);
  glDrawElementsInstanced(GL_TRIANGLES, m.nidx, GL_UNSIGNED_INT, nil, count);
end;

procedure mesh_free(var m: TMesh);
begin
  if m.ibo <> 0 then glDeleteBuffers(1, @m.ibo);
  if m.vbo <> 0 then glDeleteBuffers(1, @m.vbo);
  if m.ivbo <> 0 then glDeleteBuffers(1, @m.ivbo);
  if m.vao <> 0 then glDeleteVertexArrays(1, @m.vao);
  FillChar(m, SizeOf(m), 0);
end;

{ =========================================================================
  Генераторы примитивов
  ========================================================================= }

procedure push_vert(var v: TVertexArray; var n: Integer;
                    const p, nrm: TVec3; uu, vv: Single);
begin
  if n >= Length(v) then SetLength(v, n * 2 + 64);
  v[n].px := p.x; v[n].py := p.y; v[n].pz := p.z;
  v[n].nx := nrm.x; v[n].ny := nrm.y; v[n].nz := nrm.z;
  v[n].u := uu; v[n].v := vv;
  Inc(n);
end;

procedure push_tri(var a: TIndexArray; var n: Integer; i0, i1, i2: Integer);
begin
  if n + 3 > Length(a) then SetLength(a, (n + 3) * 2 + 64);
  a[n] := i0; a[n + 1] := i1; a[n + 2] := i2;
  Inc(n, 3);
end;

function mesh_make_box(const half: TVec3): TMesh;
var
  verts: TVertexArray;
  idx: TIndexArray;
  nv, ni, f, base: Integer;
  nrm, tx, ty, p: TVec3;
  normals: array[0..5] of TVec3;
  su, sv: Single;
  i: Integer;
begin
  verts := nil; idx := nil;
  nv := 0; ni := 0;

  normals[0] := v3( 1, 0, 0); normals[1] := v3(-1, 0, 0);
  normals[2] := v3( 0, 1, 0); normals[3] := v3( 0,-1, 0);
  normals[4] := v3( 0, 0, 1); normals[5] := v3( 0, 0,-1);

  { У каждой грани свои вершины -- нормали должны быть разрывными,
    иначе освещение куба "поплывёт". }
  for f := 0 to 5 do
  begin
    nrm := normals[f];
    v3_basis(nrm, tx, ty);
    su := Abs(tx.x) * half.x + Abs(tx.y) * half.y + Abs(tx.z) * half.z;
    sv := Abs(ty.x) * half.x + Abs(ty.y) * half.y + Abs(ty.z) * half.z;
    base := nv;
    for i := 0 to 3 do
    begin
      p := v3_mula(nrm, half);
      case i of
        0: p := v3_add(p, v3_add(v3_mul(tx, -su), v3_mul(ty, -sv)));
        1: p := v3_add(p, v3_add(v3_mul(tx,  su), v3_mul(ty, -sv)));
        2: p := v3_add(p, v3_add(v3_mul(tx,  su), v3_mul(ty,  sv)));
        3: p := v3_add(p, v3_add(v3_mul(tx, -su), v3_mul(ty,  sv)));
      end;
      case i of
        0: push_vert(verts, nv, p, nrm, 0, 0);
        1: push_vert(verts, nv, p, nrm, 1, 0);
        2: push_vert(verts, nv, p, nrm, 1, 1);
        3: push_vert(verts, nv, p, nrm, 0, 1);
      end;
    end;
    push_tri(idx, ni, base + 0, base + 1, base + 2);
    push_tri(idx, ni, base + 0, base + 2, base + 3);
  end;

  SetLength(verts, nv);
  SetLength(idx, ni);
  Result := mesh_upload(verts, idx);
end;

function mesh_make_sphere(r: Single; segs, rings: Integer): TMesh;
var
  verts: TVertexArray;
  idx: TIndexArray;
  nv, ni, i, j: Integer;
  phi, theta, sp, cp, st, ct: Single;
  n: TVec3;
  a, b, c, d: Integer;
begin
  verts := nil; idx := nil;
  nv := 0; ni := 0;

  for i := 0 to rings do
  begin
    theta := PI_F * i / rings;
    st := Sin(theta); ct := Cos(theta);
    for j := 0 to segs do
    begin
      phi := 2 * PI_F * j / segs;
      sp := Sin(phi); cp := Cos(phi);
      n := v3(st * cp, ct, st * sp);
      push_vert(verts, nv, v3_mul(n, r), n, j / segs, i / rings);
    end;
  end;

  for i := 0 to rings - 1 do
    for j := 0 to segs - 1 do
    begin
      a := i * (segs + 1) + j;
      b := a + segs + 1;
      c := a + 1;
      d := b + 1;
      push_tri(idx, ni, a, b, c);
      push_tri(idx, ni, c, b, d);
    end;

  SetLength(verts, nv);
  SetLength(idx, ni);
  Result := mesh_upload(verts, idx);
end;

function mesh_make_capsule(r, halfheight: Single; segs, rings: Integer): TMesh;
var
  verts: TVertexArray;
  idx: TIndexArray;
  nv, ni, i, j: Integer;
  theta, phi, st, ct, sp, cp, yoff: Single;
  n, p: TVec3;
  a, b, c, d: Integer;
begin
  verts := nil; idx := nil;
  nv := 0; ni := 0;

  { Капсула -- это сфера, разрезанная пополам и раздвинутая по Y. }
  for i := 0 to rings do
  begin
    theta := PI_F * i / rings;
    st := Sin(theta); ct := Cos(theta);
    if ct >= 0 then yoff := halfheight else yoff := -halfheight;
    for j := 0 to segs do
    begin
      phi := 2 * PI_F * j / segs;
      sp := Sin(phi); cp := Cos(phi);
      n := v3(st * cp, ct, st * sp);
      p := v3_mul(n, r);
      p.y := p.y + yoff;
      push_vert(verts, nv, p, n, j / segs, i / rings);
    end;
  end;

  for i := 0 to rings - 1 do
    for j := 0 to segs - 1 do
    begin
      a := i * (segs + 1) + j;
      b := a + segs + 1;
      c := a + 1;
      d := b + 1;
      push_tri(idx, ni, a, b, c);
      push_tri(idx, ni, c, b, d);
    end;

  SetLength(verts, nv);
  SetLength(idx, ni);
  Result := mesh_upload(verts, idx);
end;

function mesh_make_plane(size: Single; tiles: Integer): TMesh;
var
  verts: TVertexArray;
  idx: TIndexArray;
  nv, ni, i, j: Integer;
  x, z, step: Single;
  a, b, c, d: Integer;
begin
  verts := nil; idx := nil;
  nv := 0; ni := 0;
  step := size * 2 / tiles;

  for i := 0 to tiles do
    for j := 0 to tiles do
    begin
      x := -size + j * step;
      z := -size + i * step;
      push_vert(verts, nv, v3(x, 0, z), v3(0, 1, 0), j, i);
    end;

  for i := 0 to tiles - 1 do
    for j := 0 to tiles - 1 do
    begin
      a := i * (tiles + 1) + j;
      b := a + tiles + 1;
      c := a + 1;
      d := b + 1;
      push_tri(idx, ni, a, b, c);
      push_tri(idx, ni, c, b, d);
    end;

  SetLength(verts, nv);
  SetLength(idx, ni);
  Result := mesh_upload(verts, idx);
end;

procedure box_hull_points(const half: TVec3; out pts: array of TVec3);
var
  i: Integer;
  sx, sy, sz: Single;
begin
  for i := 0 to 7 do
  begin
    if (i and 1) <> 0 then sx := 1 else sx := -1;
    if (i and 2) <> 0 then sy := 1 else sy := -1;
    if (i and 4) <> 0 then sz := 1 else sz := -1;
    pts[i] := v3(half.x * sx, half.y * sy, half.z * sz);
  end;
end;

end.
