{ ============================================================================
  ugeom.pas  --  построение геометрии примитивов

  Модуль намеренно ничего не знает про OpenGL: он только заполняет массивы
  вершин и индексов. Благодаря этому ту же геометрию можно проверять
  тестами и рисовать программным растеризатором на машине без видеокарты.
  ============================================================================ }
unit ugeom;

{$MODE OBJFPC}
{$H+}
{$INLINE ON}

interface

uses
  umath;

type
  { Вершина занимает ровно 32 байта: позиция, нормаль, UV.
    Половина строки кэша, выровнено, видеокарте удобно. }
  TVertex = record
    px, py, pz: Single;
    nx, ny, nz: Single;
    u, v      : Single;
  end;
  PVertex = ^TVertex;

  TVertexArray = array of TVertex;
  TIndexArray  = array of Cardinal;

  { Данные одного экземпляра для инстансной отрисовки: матрица модели
    и цвет. Ровно 80 байт; раскладка должна совпадать со смещениями,
    которые передаются в glVertexAttribPointer (0 и 64). }
  TInstance = record
    model: TMat4;
    color: TVec4;
  end;
  PInstance = ^TInstance;

{ Генераторы заполняют массивы и возвращают число вершин/индексов. }
procedure geom_box(const half: TVec3; out verts: TVertexArray; out idx: TIndexArray);
procedure geom_sphere(r: Single; segs, rings: Integer;
                      out verts: TVertexArray; out idx: TIndexArray);
procedure geom_capsule(r, halfheight: Single; segs, rings: Integer;
                       out verts: TVertexArray; out idx: TIndexArray);
procedure geom_plane(size: Single; tiles: Integer;
                     out verts: TVertexArray; out idx: TIndexArray);

{ Вершины бокса как набор точек для выпуклой оболочки физики. }
procedure box_hull_points(const half: TVec3; out pts: array of TVec3);

{ Габариты и радиус описанной сферы -- нужны отсечению по пирамиде видимости. }
procedure geom_bounds(const verts: TVertexArray; out box: TAABB; out radius: Single);

implementation

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

{ То же, но вырожденные треугольники не попадают в буфер. На полюсах
  сферы вершины кольца сливаются в одну точку, и без этой проверки
  в индексный буфер уезжает 2*segs треугольников нулевой площади --
  видеокарта их всё равно выбросит, но место и пропускную способность
  они занимают. }
procedure push_tri_nd(const v: TVertexArray; var a: TIndexArray;
                      var n: Integer; i0, i1, i2: Integer);
var
  p0, p1, p2, cr: TVec3;
begin
  p0 := v3(v[i0].px, v[i0].py, v[i0].pz);
  p1 := v3(v[i1].px, v[i1].py, v[i1].pz);
  p2 := v3(v[i2].px, v[i2].py, v[i2].pz);
  cr := v3_cross(v3_sub(p1, p0), v3_sub(p2, p0));
  if v3_lensq(cr) < 1.0e-14 then Exit;
  push_tri(a, n, i0, i1, i2);
end;

procedure geom_box(const half: TVec3; out verts: TVertexArray; out idx: TIndexArray);
var
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
end;

procedure geom_sphere(r: Single; segs, rings: Integer;
                      out verts: TVertexArray; out idx: TIndexArray);
var
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
      { Кольца идут сверху вниз, сегменты -- по возрастанию угла, поэтому
        обход против часовой стрелки (наружу) выглядит именно так. }
      push_tri_nd(verts, idx, ni, a, c, b);
      push_tri_nd(verts, idx, ni, c, d, b);
    end;

  SetLength(verts, nv);
  SetLength(idx, ni);
end;

procedure geom_capsule(r, halfheight: Single; segs, rings: Integer;
                       out verts: TVertexArray; out idx: TIndexArray);
var
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
      { Кольца идут сверху вниз, сегменты -- по возрастанию угла, поэтому
        обход против часовой стрелки (наружу) выглядит именно так. }
      push_tri_nd(verts, idx, ni, a, c, b);
      push_tri_nd(verts, idx, ni, c, d, b);
    end;

  SetLength(verts, nv);
  SetLength(idx, ni);
end;

procedure geom_plane(size: Single; tiles: Integer;
                     out verts: TVertexArray; out idx: TIndexArray);
var
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


procedure geom_bounds(const verts: TVertexArray; out box: TAABB; out radius: Single);
var
  i: Integer;
  p: TVec3;
  d: Single;
begin
  box := aabb_empty;
  radius := 0;
  for i := 0 to High(verts) do
  begin
    p := v3(verts[i].px, verts[i].py, verts[i].pz);
    aabb_add(box, p);
    d := v3_lensq(p);
    if d > radius then radius := d;
  end;
  radius := Sqrt(radius);
end;

end.
