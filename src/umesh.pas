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
  umath, ugl, ugeom;

type
  { Вершина и массивы геометрии живут в ugeom -- здесь только псевдонимы,
    чтобы не тащить ugeom в каждый модуль, который рисует. }
  TVertex      = ugeom.TVertex;
  PVertex      = ugeom.PVertex;
  TVertexArray = ugeom.TVertexArray;
  TIndexArray  = ugeom.TIndexArray;
  TInstance    = ugeom.TInstance;
  PInstance    = ugeom.PInstance;

  TMesh = record
    vao, vbo, ibo, ivbo: GLuint;
    nverts, nidx       : Integer;
    maxInstances       : Integer;
    bounds             : TAABB;
    radius             : Single;
  end;
  PMesh = ^TMesh;

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

implementation

function mesh_upload(const verts: TVertexArray; const idx: TIndexArray): TMesh;
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
  geom_bounds(verts, Result.bounds, Result.radius);
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
  Примитивы: геометрия берётся из ugeom, здесь только загрузка в видеопамять
  ========================================================================= }

function mesh_make_box(const half: TVec3): TMesh;
var
  verts: TVertexArray;
  idx: TIndexArray;
begin
  geom_box(half, verts, idx);
  Result := mesh_upload(verts, idx);
end;

function mesh_make_sphere(r: Single; segs, rings: Integer): TMesh;
var
  verts: TVertexArray;
  idx: TIndexArray;
begin
  geom_sphere(r, segs, rings, verts, idx);
  Result := mesh_upload(verts, idx);
end;

function mesh_make_capsule(r, halfheight: Single; segs, rings: Integer): TMesh;
var
  verts: TVertexArray;
  idx: TIndexArray;
begin
  geom_capsule(r, halfheight, segs, rings, verts, idx);
  Result := mesh_upload(verts, idx);
end;

function mesh_make_plane(size: Single; tiles: Integer): TMesh;
var
  verts: TVertexArray;
  idx: TIndexArray;
begin
  geom_plane(size, tiles, verts, idx);
  Result := mesh_upload(verts, idx);
end;

end.
