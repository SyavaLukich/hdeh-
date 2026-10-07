{ ============================================================================
  ugjk.pas  --  выпуклые формы, GJK и EPA

  Здесь живёт "узкая фаза" физики:
    * описание выпуклых форм через функцию поддержки (support mapping);
    * алгоритм GJK -- проверка пересечения и поиск ближайших точек;
    * алгоритм EPA -- глубина и нормаль проникновения после GJK.

  Структуры данных сделаны плоскими и фиксированного размера: симплекс и
  политоп EPA лежат на стеке, за время шага физики не делается ни одной
  аллокации. Это и есть главный приём оптимизации под современное железо --
  предсказуемые ветвления и данные в L1-кэше.
  ============================================================================ }
unit ugjk;

{$MODE OBJFPC}
{$H+}
{$INLINE ON}
{$OPTIMIZATION LEVEL3}

interface

uses
  umath;

const
  GJK_MAX_ITER      = 32;
  EPA_MAX_ITER      = 48;
  EPA_MAX_FACES     = 128;
  EPA_MAX_EDGES     = 64;
  EPA_MAX_VERTS     = 96;
  HULL_MAX_POINTS   = 64;   { достаточно для игровых выпуклых тел }

type
  TShapeKind = (SHAPE_SPHERE, SHAPE_BOX, SHAPE_CAPSULE, SHAPE_HULL);

  { Единая форма. Вместо иерархии классов -- тег и объединение полей.
    Размер записи фиксирован, формы лежат в одном плотном массиве. }
  TShape = record
    kind     : TShapeKind;
    radius   : Single;                            { сфера / капсула / скругление }
    half     : TVec3;                             { полуразмеры бокса }
    height   : Single;                            { половина высоты капсулы по Y }
    npts     : Integer;                           { число точек выпуклой оболочки }
    pts      : array[0..HULL_MAX_POINTS - 1] of TVec3;
  end;
  PShape = ^TShape;

  { Поза тела: только поворот и перенос, масштаб в физике не нужен. }
  TPose = record
    p: TVec3;
    q: TQuat;
  end;

  TSimplex = record
    a, b, c, d: TVec3;   { точки разности Минковского }
    n: Integer;
  end;

  { Результат узкой фазы }
  TGJKResult = record
    hit      : Boolean;
    normal   : TVec3;    { из A в B, нормирована }
    depth    : Single;   { глубина проникновения, >= 0 }
    pointA   : TVec3;    { точка на теле A в мировых координатах }
    pointB   : TVec3;
    distance : Single;   { расстояние, если тела не пересекаются }
  end;

{ ---- конструкторы форм ---- }
function shape_sphere(r: Single): TShape;
function shape_box(const half: TVec3): TShape;
function shape_capsule(r, halfheight: Single): TShape;
function shape_hull(const pts: array of TVec3): TShape;

function pose_make(const p: TVec3; const q: TQuat): TPose; inline;
function pose_identity: TPose; inline;

{ Функция поддержки в локальных координатах формы. }
function shape_support_local(const s: TShape; const dir: TVec3): TVec3;
{ Функция поддержки в мировых координатах. }
function shape_support(const s: TShape; const t: TPose; const dir: TVec3): TVec3; inline;
{ AABB формы в мировых координатах (с запасом margin). }
function shape_aabb(const s: TShape; const t: TPose; margin: Single): TAABB;
{ Тензор инерции однородного тела заданной массы. }
function shape_inertia(const s: TShape; mass: Single): TMat3;
function shape_volume(const s: TShape): Single;

{ Главная точка входа: пересекаются ли формы, и если да -- насколько глубоко.
  Возвращает True при пересечении. }
function gjk_collide(const sa: TShape; const ta: TPose;
                     const sb: TShape; const tb: TPose;
                     out res: TGJKResult): Boolean;

{ Только булев тест -- заметно быстрее, когда глубина не нужна. }
function gjk_intersect(const sa: TShape; const ta: TPose;
                       const sb: TShape; const tb: TPose): Boolean;

{ Расстояние между непересекающимися формами и ближайшие точки. }
function gjk_distance(const sa: TShape; const ta: TPose;
                      const sb: TShape; const tb: TPose;
                      out pa, pb: TVec3): Single;

{ Бросок луча по выпуклой форме (conservative advancement на базе GJK). }
function gjk_raycast(const s: TShape; const t: TPose;
                     const ro, rd: TVec3; maxdist: Single;
                     out tHit: Single; out nHit: TVec3): Boolean;

implementation

{ =========================================================================
  Формы
  ========================================================================= }

function shape_sphere(r: Single): TShape;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.kind := SHAPE_SPHERE;
  Result.radius := r;
end;

function shape_box(const half: TVec3): TShape;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.kind := SHAPE_BOX;
  Result.half := half;
  Result.radius := 0;
end;

function shape_capsule(r, halfheight: Single): TShape;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.kind := SHAPE_CAPSULE;
  Result.radius := r;
  Result.height := halfheight;
end;

function shape_hull(const pts: array of TVec3): TShape;
var
  i, n: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.kind := SHAPE_HULL;
  n := Length(pts);
  if n > HULL_MAX_POINTS then n := HULL_MAX_POINTS;
  for i := 0 to n - 1 do Result.pts[i] := pts[i];
  Result.npts := n;
  Result.radius := 0;
end;

function pose_make(const p: TVec3; const q: TQuat): TPose;
begin
  Result.p := p;
  Result.q := q;
end;

function pose_identity: TPose;
begin
  Result.p := v3_zero;
  Result.q := q_identity;
end;

function shape_support_local(const s: TShape; const dir: TVec3): TVec3;
var
  i, best: Integer;
  d, bestd: Single;
begin
  case s.kind of
    SHAPE_SPHERE:
      Result := v3_mul(v3_norm(dir), s.radius);

    SHAPE_BOX:
      begin
        { Самая дешёвая функция поддержки: по знаку компоненты направления. }
        if dir.x >= 0 then Result.x := s.half.x else Result.x := -s.half.x;
        if dir.y >= 0 then Result.y := s.half.y else Result.y := -s.half.y;
        if dir.z >= 0 then Result.z := s.half.z else Result.z := -s.half.z;
      end;

    SHAPE_CAPSULE:
      begin
        if dir.y >= 0 then Result := v3(0, s.height, 0)
                      else Result := v3(0, -s.height, 0);
        Result := v3_add(Result, v3_mul(v3_norm(dir), s.radius));
      end;

    SHAPE_HULL:
      begin
        { Линейный перебор. Для 8..64 точек это 1-2 строки кэша и
          полностью векторизуемый цикл -- быстрее иерархии Dobkin-Kirkpatrick. }
        best := 0;
        bestd := -1.0e30;
        for i := 0 to s.npts - 1 do
        begin
          d := s.pts[i].x * dir.x + s.pts[i].y * dir.y + s.pts[i].z * dir.z;
          if d > bestd then
          begin
            bestd := d;
            best := i;
          end;
        end;
        Result := s.pts[best];
        if s.radius > 0 then
          Result := v3_add(Result, v3_mul(v3_norm(dir), s.radius));
      end;
  else
    Result := v3_zero;
  end;
end;

function shape_support(const s: TShape; const t: TPose; const dir: TVec3): TVec3;
var
  ld: TVec3;
begin
  { Переводим направление в локальные координаты сопряжённым кватернионом,
    ищем опорную точку, возвращаем обратно в мир. }
  ld := q_rotate(q_conj(t.q), dir);
  Result := v3_add(t.p, q_rotate(t.q, shape_support_local(s, ld)));
end;

function shape_aabb(const s: TShape; const t: TPose; margin: Single): TAABB;
var
  i: Integer;
  p: TVec3;
  dirs: array[0..5] of TVec3;
begin
  case s.kind of
    SHAPE_SPHERE:
      begin
        Result.mn := v3(t.p.x - s.radius, t.p.y - s.radius, t.p.z - s.radius);
        Result.mx := v3(t.p.x + s.radius, t.p.y + s.radius, t.p.z + s.radius);
      end;
  else
    begin
      { Универсальный путь: шесть вызовов функции поддержки по осям мира. }
      dirs[0] := v3( 1, 0, 0); dirs[1] := v3(-1, 0, 0);
      dirs[2] := v3( 0, 1, 0); dirs[3] := v3( 0,-1, 0);
      dirs[4] := v3( 0, 0, 1); dirs[5] := v3( 0, 0,-1);
      Result := aabb_empty;
      for i := 0 to 5 do
      begin
        p := shape_support(s, t, dirs[i]);
        aabb_add(Result, p);
      end;
    end;
  end;
  Result := aabb_expand(Result, margin);
end;

function shape_volume(const s: TShape): Single;
var
  i: Integer;
  b: TAABB;
  e: TVec3;
begin
  case s.kind of
    SHAPE_SPHERE: Result := (4.0 / 3.0) * PI_F * s.radius * s.radius * s.radius;
    SHAPE_BOX:    Result := 8.0 * s.half.x * s.half.y * s.half.z;
    SHAPE_CAPSULE:
      Result := PI_F * s.radius * s.radius * (2.0 * s.height) +
                (4.0 / 3.0) * PI_F * s.radius * s.radius * s.radius;
  else
    begin
      { Для оболочки берём объём её AABB с поправкой 0.5 -- для игровой
        физики точность тензора инерции не критична. }
      b := aabb_empty;
      for i := 0 to s.npts - 1 do aabb_add(b, s.pts[i]);
      e := v3_sub(b.mx, b.mn);
      Result := e.x * e.y * e.z * 0.5;
    end;
  end;
end;

function shape_inertia(const s: TShape; mass: Single): TMat3;
var
  i: Integer;
  b: TAABB;
  h: TVec3;
  r2, ix, iy, iz: Single;
begin
  Result := m3_identity;
  case s.kind of
    SHAPE_SPHERE:
      begin
        r2 := 0.4 * mass * s.radius * s.radius;
        Result.m[0] := r2; Result.m[4] := r2; Result.m[8] := r2;
      end;

    SHAPE_BOX:
      begin
        h := v3_mul(s.half, 2.0);
        ix := mass * (h.y * h.y + h.z * h.z) / 12.0;
        iy := mass * (h.x * h.x + h.z * h.z) / 12.0;
        iz := mass * (h.x * h.x + h.y * h.y) / 12.0;
        Result.m[0] := ix; Result.m[4] := iy; Result.m[8] := iz;
      end;

    SHAPE_CAPSULE:
      begin
        { Приближаем цилиндром той же массы -- погрешность в пределах 10%. }
        ix := mass * (3.0 * s.radius * s.radius +
                      4.0 * s.height * s.height) / 12.0;
        iy := 0.5 * mass * s.radius * s.radius;
        Result.m[0] := ix; Result.m[4] := iy; Result.m[8] := ix;
      end;

    SHAPE_HULL:
      begin
        b := aabb_empty;
        for i := 0 to s.npts - 1 do aabb_add(b, s.pts[i]);
        h := v3_sub(b.mx, b.mn);
        ix := mass * (h.y * h.y + h.z * h.z) / 12.0;
        iy := mass * (h.x * h.x + h.z * h.z) / 12.0;
        iz := mass * (h.x * h.x + h.y * h.y) / 12.0;
        Result.m[0] := ix; Result.m[4] := iy; Result.m[8] := iz;
      end;
  end;
end;

{ =========================================================================
  GJK

  Работаем с разностью Минковского A (-) B. Если её выпуклая оболочка
  содержит начало координат -- тела пересекаются. Симплекс наращиваем
  до тетраэдра, каждый шаг отбрасывая области Вороного, которые не могут
  содержать начало координат.
  ========================================================================= }

type
  { Вершина симплекса вместе с опорными точками на обоих телах -- нужны,
    чтобы восстановить точки контакта барицентрической интерполяцией. }
  TSupportVert = record
    v : TVec3;   { v = pa - pb }
    pa: TVec3;
    pb: TVec3;
  end;

  TSimplexW = record
    w: array[0..3] of TSupportVert;
    n: Integer;
  end;

function minkowski_support(const sa: TShape; const ta: TPose;
                           const sb: TShape; const tb: TPose;
                           const dir: TVec3): TSupportVert; inline;
begin
  Result.pa := shape_support(sa, ta, dir);
  Result.pb := shape_support(sb, tb, v3_neg(dir));
  Result.v  := v3_sub(Result.pa, Result.pb);
end;

{ Обработка симплекса: уточняем направление поиска и, если нужно,
  уменьшаем симплекс. Возвращает True, если начало координат внутри. }
function do_simplex(var s: TSimplexW; var dir: TVec3): Boolean;
var
  a, b, c, d, ao, ab, ac, ad, abc, acd, adb: TVec3;
  wa, wb, wc, wd: TSupportVert;

  procedure set1(const x: TSupportVert);
  begin
    s.w[0] := x; s.n := 1;
  end;

  procedure set2(const x, y: TSupportVert);
  begin
    s.w[0] := x; s.w[1] := y; s.n := 2;
  end;

  procedure set3(const x, y, z: TSupportVert);
  begin
    s.w[0] := x; s.w[1] := y; s.w[2] := z; s.n := 3;
  end;

begin
  Result := False;

  case s.n of
    2:
      begin
        wa := s.w[1]; wb := s.w[0];     { a -- добавленная последней }
        a := wa.v; b := wb.v;
        ao := v3_neg(a);
        ab := v3_sub(b, a);
        if v3_dot(ab, ao) > 0 then
        begin
          dir := v3_cross(v3_cross(ab, ao), ab);
          if v3_lensq(dir) < EPS_SQR then
            { начало координат лежит на отрезке -- берём любую перпендикуляр }
            v3_basis(v3_norm(ab), dir, ac);
          set2(wb, wa);
        end
        else
        begin
          dir := ao;
          set1(wa);
        end;
      end;

    3:
      begin
        wa := s.w[2]; wb := s.w[1]; wc := s.w[0];
        a := wa.v; b := wb.v; c := wc.v;
        ao := v3_neg(a);
        ab := v3_sub(b, a);
        ac := v3_sub(c, a);
        abc := v3_cross(ab, ac);

        if v3_dot(v3_cross(abc, ac), ao) > 0 then
        begin
          if v3_dot(ac, ao) > 0 then
          begin
            dir := v3_cross(v3_cross(ac, ao), ac);
            set2(wc, wa);
          end
          else
          begin
            dir := v3_cross(v3_cross(ab, ao), ab);
            set2(wb, wa);
          end;
        end
        else if v3_dot(v3_cross(ab, abc), ao) > 0 then
        begin
          dir := v3_cross(v3_cross(ab, ao), ab);
          set2(wb, wa);
        end
        else
        begin
          if v3_dot(abc, ao) > 0 then
          begin
            dir := abc;
            set3(wc, wb, wa);
          end
          else
          begin
            dir := v3_neg(abc);
            set3(wb, wc, wa);
          end;
        end;
      end;

    4:
      begin
        wa := s.w[3]; wb := s.w[2]; wc := s.w[1]; wd := s.w[0];
        a := wa.v; b := wb.v; c := wc.v; d := wd.v;
        ao := v3_neg(a);
        ab := v3_sub(b, a);
        ac := v3_sub(c, a);
        ad := v3_sub(d, a);
        abc := v3_cross(ab, ac);
        acd := v3_cross(ac, ad);
        adb := v3_cross(ad, ab);

        if v3_dot(abc, ao) > 0 then
        begin
          set3(wc, wb, wa);
          dir := abc;
        end
        else if v3_dot(acd, ao) > 0 then
        begin
          set3(wd, wc, wa);
          dir := acd;
        end
        else if v3_dot(adb, ao) > 0 then
        begin
          set3(wb, wd, wa);
          dir := adb;
        end
        else
          Result := True;    { начало координат внутри тетраэдра }
      end;
  end;
end;

{ Ядро GJK. Возвращает True при пересечении и отдаёт финальный симплекс. }
function gjk_core(const sa: TShape; const ta: TPose;
                  const sb: TShape; const tb: TPose;
                  out simp: TSimplexW): Boolean;
var
  dir: TVec3;
  sv: TSupportVert;
  iter: Integer;
begin
  dir := v3_sub(tb.p, ta.p);
  if v3_lensq(dir) < EPS_SQR then dir := v3(1, 0, 0);

  simp.n := 0;
  sv := minkowski_support(sa, ta, sb, tb, dir);
  simp.w[0] := sv;
  simp.n := 1;
  dir := v3_neg(sv.v);

  for iter := 1 to GJK_MAX_ITER do
  begin
    if v3_lensq(dir) < EPS_SQR then
    begin
      Result := True;    { начало координат на границе -- считаем касанием }
      Exit;
    end;

    sv := minkowski_support(sa, ta, sb, tb, dir);

    { Если самая дальняя точка в сторону начала координат его не достала --
      пересечения нет. }
    if v3_dot(sv.v, dir) < 0 then
    begin
      Result := False;
      Exit;
    end;

    simp.w[simp.n] := sv;
    Inc(simp.n);

    if do_simplex(simp, dir) then
    begin
      Result := True;
      Exit;
    end;
  end;

  { Итерации кончились -- считаем, что пересечения нет (устойчивее, чем
    выдавать мусорную нормаль). }
  Result := False;
end;

function gjk_intersect(const sa: TShape; const ta: TPose;
                       const sb: TShape; const tb: TPose): Boolean;
var simp: TSimplexW;
begin
  Result := gjk_core(sa, ta, sb, tb, simp);
end;

{ =========================================================================
  EPA -- Expanding Polytope Algorithm

  Начинаем с тетраэдра, полученного от GJK, и раздуваем его в сторону
  ближайшей грани, пока прирост расстояния не станет меньше допуска.
  Нормаль ближайшей грани и есть нормаль контакта, её расстояние до начала
  координат -- глубина проникновения.
  ========================================================================= }

type
  TEpaFace = record
    a, b, c : Integer;   { индексы вершин }
    n       : TVec3;     { нормаль наружу }
    dist    : Single;    { расстояние плоскости до начала координат }
    alive   : Boolean;
  end;

  TEpaEdge = record
    a, b: Integer;
  end;

function epa_make_face(const verts: array of TSupportVert;
                       ia, ib, ic: Integer): TEpaFace;
var
  n: TVec3;
  l: Single;
begin
  Result.a := ia; Result.b := ib; Result.c := ic;
  Result.alive := True;
  n := v3_cross(v3_sub(verts[ib].v, verts[ia].v),
                v3_sub(verts[ic].v, verts[ia].v));
  l := v3_len(n);
  if l > EPS then
    n := v3_mul(n, 1.0 / l)
  else
    n := v3(0, 1, 0);
  { Ориентируем нормаль наружу относительно начала координат. }
  if v3_dot(n, verts[ia].v) < 0 then
  begin
    n := v3_neg(n);
    Result.b := ic;
    Result.c := ib;
  end;
  Result.n := n;
  Result.dist := v3_dot(Result.n, verts[Result.a].v);
end;

{ Барицентрические координаты проекции начала координат на треугольник --
  ими восстанавливаем точки контакта на обоих телах. }
procedure bary_origin(const a, b, c: TVec3; out u, v, w: Single);
var
  v0, v1, v2: TVec3;
  d00, d01, d11, d20, d21, den: Single;
begin
  v0 := v3_sub(b, a);
  v1 := v3_sub(c, a);
  v2 := v3_neg(a);
  d00 := v3_dot(v0, v0);
  d01 := v3_dot(v0, v1);
  d11 := v3_dot(v1, v1);
  d20 := v3_dot(v2, v0);
  d21 := v3_dot(v2, v1);
  den := d00 * d11 - d01 * d01;
  if Abs(den) < 1.0e-20 then
  begin
    u := 1; v := 0; w := 0;
    Exit;
  end;
  v := (d11 * d20 - d01 * d21) / den;
  w := (d00 * d21 - d01 * d20) / den;
  u := 1.0 - v - w;
end;

function epa_run(const sa: TShape; const ta: TPose;
                 const sb: TShape; const tb: TPose;
                 const simp: TSimplexW; out res: TGJKResult): Boolean;
var
  verts: array[0..EPA_MAX_VERTS - 1] of TSupportVert;
  faces: array[0..EPA_MAX_FACES - 1] of TEpaFace;
  edges: array[0..EPA_MAX_EDGES - 1] of TEpaEdge;
  nverts, nfaces, nedges: Integer;
  i, j, iter, best: Integer;
  bestd, d: Single;
  sv: TSupportVert;
  u, vv, w: Single;
  pa, pb: TVec3;
  found: Boolean;

  procedure add_edge(a, b: Integer);
  var k: Integer;
  begin
    { Если обратное ребро уже в списке -- оба внутренние, убираем пару.
      Это классический приём построения "горизонта" видимых граней. }
    for k := 0 to nedges - 1 do
      if (edges[k].a = b) and (edges[k].b = a) then
      begin
        edges[k] := edges[nedges - 1];
        Dec(nedges);
        Exit;
      end;
    if nedges < EPA_MAX_EDGES then
    begin
      edges[nedges].a := a;
      edges[nedges].b := b;
      Inc(nedges);
    end;
  end;

begin
  Result := False;
  if simp.n < 4 then Exit;

  nverts := 4;
  for i := 0 to 3 do verts[i] := simp.w[i];

  nfaces := 0;
  faces[nfaces] := epa_make_face(verts, 0, 1, 2); Inc(nfaces);
  faces[nfaces] := epa_make_face(verts, 0, 2, 3); Inc(nfaces);
  faces[nfaces] := epa_make_face(verts, 0, 3, 1); Inc(nfaces);
  faces[nfaces] := epa_make_face(verts, 1, 3, 2); Inc(nfaces);

  for iter := 1 to EPA_MAX_ITER do
  begin
    { 1. Ищем ближайшую к началу координат живую грань. }
    best := -1;
    bestd := 1.0e30;
    for i := 0 to nfaces - 1 do
      if faces[i].alive and (faces[i].dist < bestd) then
      begin
        bestd := faces[i].dist;
        best := i;
      end;
    if best < 0 then Exit;

    { 2. Берём опорную точку в сторону нормали этой грани. }
    sv := minkowski_support(sa, ta, sb, tb, faces[best].n);
    d := v3_dot(sv.v, faces[best].n);

    { 3. Если дальше двигаться некуда -- грань и есть ответ. }
    if (d - bestd < 1.0e-4) or (nverts >= EPA_MAX_VERTS) or
       (iter = EPA_MAX_ITER) then
    begin
      bary_origin(verts[faces[best].a].v,
                  verts[faces[best].b].v,
                  verts[faces[best].c].v, u, vv, w);
      pa := v3_add(v3_add(v3_mul(verts[faces[best].a].pa, u),
                          v3_mul(verts[faces[best].b].pa, vv)),
                   v3_mul(verts[faces[best].c].pa, w));
      pb := v3_add(v3_add(v3_mul(verts[faces[best].a].pb, u),
                          v3_mul(verts[faces[best].b].pb, vv)),
                   v3_mul(verts[faces[best].c].pb, w));
      res.hit := True;
      res.normal := faces[best].n;
      res.depth := fmax(bestd, 0.0);
      res.pointA := pa;
      res.pointB := pb;
      res.distance := 0;
      Result := True;
      Exit;
    end;

    { 4. Удаляем все грани, которые видно из новой точки, собираем горизонт. }
    nedges := 0;
    for i := 0 to nfaces - 1 do
      if faces[i].alive then
        if v3_dot(faces[i].n, v3_sub(sv.v, verts[faces[i].a].v)) > 0 then
        begin
          faces[i].alive := False;
          add_edge(faces[i].a, faces[i].b);
          add_edge(faces[i].b, faces[i].c);
          add_edge(faces[i].c, faces[i].a);
        end;

    { 5. Уплотняем список граней, выбрасывая мёртвые. }
    j := 0;
    for i := 0 to nfaces - 1 do
      if faces[i].alive then
      begin
        faces[j] := faces[i];
        Inc(j);
      end;
    nfaces := j;

    { 6. Достраиваем политоп новой вершиной. }
    verts[nverts] := sv;
    Inc(nverts);
    found := False;
    for i := 0 to nedges - 1 do
    begin
      if nfaces >= EPA_MAX_FACES then Break;
      faces[nfaces] := epa_make_face(verts, edges[i].a, edges[i].b, nverts - 1);
      Inc(nfaces);
      found := True;
    end;
    if not found then Exit;
  end;
end;

function gjk_collide(const sa: TShape; const ta: TPose;
                     const sb: TShape; const tb: TPose;
                     out res: TGJKResult): Boolean;
var
  simp: TSimplexW;
  dir, perp1, perp2: TVec3;
  sv: TSupportVert;
begin
  FillChar(res, SizeOf(res), 0);
  res.normal := v3(0, 1, 0);

  if not gjk_core(sa, ta, sb, tb, simp) then
  begin
    res.hit := False;
    Result := False;
    Exit;
  end;

  { EPA нужен полноценный тетраэдр. Если GJK остановился раньше
    (касание гранью или ребром), достраиваем симплекс вручную. }
  while simp.n < 4 do
  begin
    case simp.n of
      1:
        begin
          dir := v3(1, 0, 0);
          sv := minkowski_support(sa, ta, sb, tb, dir);
          if v3_distsq(sv.v, simp.w[0].v) < EPS_SQR then
          begin
            dir := v3(0, 1, 0);
            sv := minkowski_support(sa, ta, sb, tb, dir);
          end;
        end;
      2:
        begin
          dir := v3_sub(simp.w[1].v, simp.w[0].v);
          v3_basis(v3_norm(dir), perp1, perp2);
          sv := minkowski_support(sa, ta, sb, tb, perp1);
          if v3_distsq(sv.v, simp.w[0].v) < EPS_SQR then
            sv := minkowski_support(sa, ta, sb, tb, perp2);
        end;
    else
      begin
        dir := v3_cross(v3_sub(simp.w[1].v, simp.w[0].v),
                        v3_sub(simp.w[2].v, simp.w[0].v));
        if v3_lensq(dir) < EPS_SQR then Break;
        sv := minkowski_support(sa, ta, sb, tb, dir);
        if v3_dot(v3_sub(sv.v, simp.w[0].v), dir) <= EPS then
          sv := minkowski_support(sa, ta, sb, tb, v3_neg(dir));
      end;
    end;
    simp.w[simp.n] := sv;
    Inc(simp.n);
  end;

  Result := epa_run(sa, ta, sb, tb, simp, res);
  if not Result then
  begin
    { Крайне вырожденный случай -- отдаём минимальный осмысленный контакт. }
    res.hit := True;
    res.normal := v3_norm(v3_sub(tb.p, ta.p));
    if v3_iszero(res.normal) then res.normal := v3(0, 1, 0);
    res.depth := 1.0e-4;
    res.pointA := ta.p;
    res.pointB := tb.p;
    Result := True;
  end;
end;

{ =========================================================================
  Расстояние между непересекающимися телами (GJK distance)
  ========================================================================= }

{ Ближайшая к началу координат точка треугольника, с барицентрикой. }
procedure closest_on_tri(const a, b, c: TVec3; out p: TVec3;
                         out u, v, w: Single);
var
  ab, ac, ap, bp, cp: TVec3;
  d1, d2, d3, d4, d5, d6, va, vb, vc, den, t: Single;
begin
  ab := v3_sub(b, a);
  ac := v3_sub(c, a);
  ap := v3_neg(a);
  d1 := v3_dot(ab, ap); d2 := v3_dot(ac, ap);
  if (d1 <= 0) and (d2 <= 0) then
  begin
    p := a; u := 1; v := 0; w := 0; Exit;
  end;
  bp := v3_neg(b);
  d3 := v3_dot(ab, bp); d4 := v3_dot(ac, bp);
  if (d3 >= 0) and (d4 <= d3) then
  begin
    p := b; u := 0; v := 1; w := 0; Exit;
  end;
  vc := d1 * d4 - d3 * d2;
  if (vc <= 0) and (d1 >= 0) and (d3 <= 0) then
  begin
    t := d1 / (d1 - d3);
    p := v3_mad(a, ab, t); u := 1 - t; v := t; w := 0; Exit;
  end;
  cp := v3_neg(c);
  d5 := v3_dot(ab, cp); d6 := v3_dot(ac, cp);
  if (d6 >= 0) and (d5 <= d6) then
  begin
    p := c; u := 0; v := 0; w := 1; Exit;
  end;
  vb := d5 * d2 - d1 * d6;
  if (vb <= 0) and (d2 >= 0) and (d6 <= 0) then
  begin
    t := d2 / (d2 - d6);
    p := v3_mad(a, ac, t); u := 1 - t; v := 0; w := t; Exit;
  end;
  va := d3 * d6 - d5 * d4;
  if (va <= 0) and ((d4 - d3) >= 0) and ((d5 - d6) >= 0) then
  begin
    t := (d4 - d3) / ((d4 - d3) + (d5 - d6));
    p := v3_add(b, v3_mul(v3_sub(c, b), t)); u := 0; v := 1 - t; w := t; Exit;
  end;
  den := 1.0 / (va + vb + vc);
  v := vb * den;
  w := vc * den;
  u := 1 - v - w;
  p := v3_add(a, v3_add(v3_mul(ab, v), v3_mul(ac, w)));
end;

function gjk_distance(const sa: TShape; const ta: TPose;
                      const sb: TShape; const tb: TPose;
                      out pa, pb: TVec3): Single;
var
  w: array[0..2] of TSupportVert;
  n, iter: Integer;
  dir, closest: TVec3;
  sv: TSupportVert;
  u, v, ww, dist, newdist, t: Single;
begin
  pa := ta.p; pb := tb.p;
  dir := v3_sub(tb.p, ta.p);
  if v3_lensq(dir) < EPS_SQR then dir := v3(1, 0, 0);

  w[0] := minkowski_support(sa, ta, sb, tb, v3_neg(dir));
  w[1] := w[0];
  w[2] := w[0];
  n := 1;
  closest := w[0].v;
  dist := v3_len(closest);

  for iter := 1 to GJK_MAX_ITER do
  begin
    dir := v3_neg(closest);
    if v3_lensq(dir) < EPS_SQR then
    begin
      Result := 0;
      Exit;
    end;
    sv := minkowski_support(sa, ta, sb, tb, dir);
    newdist := v3_dot(sv.v, v3_norm(dir));
    if dist - newdist < 1.0e-5 then Break;

    if n < 3 then
    begin
      w[n] := sv;
      Inc(n);
    end
    else
      w[2] := sv;

    case n of
      1: begin
           closest := w[0].v;
           u := 1; v := 0; ww := 0;
         end;
      2: begin
           { ближайшая точка отрезка }
           t := 0;
           if v3_distsq(w[0].v, w[1].v) > EPS_SQR then
             t := fclamp(v3_dot(v3_neg(w[0].v), v3_sub(w[1].v, w[0].v)) /
                         v3_distsq(w[0].v, w[1].v), 0, 1);
           closest := v3_lerp(w[0].v, w[1].v, t);
           u := 1 - t; v := t; ww := 0;
         end;
    else
      closest_on_tri(w[0].v, w[1].v, w[2].v, closest, u, v, ww);
    end;

    dist := v3_len(closest);
    pa := v3_add(v3_add(v3_mul(w[0].pa, u), v3_mul(w[1].pa, v)),
                 v3_mul(w[2].pa, ww));
    pb := v3_add(v3_add(v3_mul(w[0].pb, u), v3_mul(w[1].pb, v)),
                 v3_mul(w[2].pb, ww));
  end;

  Result := dist;
end;

{ =========================================================================
  Луч по выпуклой форме.
  Реализован через "consecutive advancement": шагаем по лучу, пока сфера
  нулевого радиуса не коснётся формы.
  ========================================================================= }

function gjk_raycast(const s: TShape; const t: TPose;
                     const ro, rd: TVec3; maxdist: Single;
                     out tHit: Single; out nHit: TVec3): Boolean;
var
  pt: TShape;
  pose: TPose;
  cur, d: Single;
  pa, pb, p: TVec3;
  iter: Integer;
begin
  pt := shape_sphere(0.0);
  pose := pose_identity;
  cur := 0;
  tHit := 0;
  nHit := v3(0, 1, 0);

  for iter := 1 to 48 do
  begin
    p := v3_mad(ro, rd, cur);
    pose.p := p;
    d := gjk_distance(pt, pose, s, t, pa, pb);
    if d < 1.0e-3 then
    begin
      tHit := cur;
      nHit := v3_norm(v3_sub(pa, pb));
      if v3_iszero(nHit) then nHit := v3_neg(rd);
      Result := True;
      Exit;
    end;
    cur := cur + d;
    if cur > maxdist then Break;
  end;
  Result := False;
end;

end.
