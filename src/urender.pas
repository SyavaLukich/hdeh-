{ ============================================================================
  urender.pas  --  рендерер

  Что умеет:
    * компиляция и хранение шейдерных программ;
    * камера (матрицы вида/проекции, пирамида видимости);
    * один инстансный проход на непрозрачную геометрию;
    * пакетная отрисовка отладочных линий.

  Главный приём оптимизации: не рисовать объекты по одному. Все одинаковые
  меши собираются в массив экземпляров и уходят на видеокарту одним
  glDrawElementsInstanced. Это убирает основной источник тормозов
  в старых движках -- тысячи вызовов отрисовки.
  ============================================================================ }
unit urender;

{$MODE OBJFPC}
{$H+}

interface

uses
  umath, ugl, ugeom, ucamera, umesh;

const
  MAX_DEBUG_LINES = 32768;

type
  { Камера живёт в отдельном модуле без зависимости от OpenGL. }
  TCamera = ucamera.TCamera;

  TShaderProgram = record
    id: GLuint;
    { закэшированные локации -- искать их каждый кадр по имени дорого }
    uViewProj, uModel, uColor, uLightDir, uCamPos, uFogColor, uFogParams,
    uAmbient, uTime: GLint;
  end;

var
  g_prog_lit  : TShaderProgram;   { инстансная освещённая геометрия }
  g_prog_line : TShaderProgram;   { отладочные линии }
  g_light_dir : TVec3;
  g_fog_color : TVec3;
  g_fog_near  : Single = 40.0;
  g_fog_far   : Single = 220.0;

function  render_init: Boolean;
procedure render_shutdown;

procedure render_begin(const c: TCamera);
procedure render_lit_begin(const c: TCamera);
procedure render_draw_batch(var m: TMesh; const inst: array of TInstance;
                            count: Integer);

{ --- отладочные линии --- }
procedure dbg_clear;
procedure dbg_line(const a, b: TVec3; const col: TVec3);
procedure dbg_aabb(const box: TAABB; const col: TVec3);
procedure dbg_cross(const p: TVec3; size: Single; const col: TVec3);
procedure dbg_flush(const c: TCamera);

function  shader_build(const vs, fs: string): TShaderProgram;

implementation

{ =========================================================================
  Исходники шейдеров.

  Держим их прямо в коде: нет зависимости от файлов рядом с бинарником,
  а компилируются они за доли миллисекунды.
  ========================================================================= }

const
  VS_LIT =
    '#version 330 core'                                              + #10 +
    'layout(location=0) in vec3 aPos;'                               + #10 +
    'layout(location=1) in vec3 aNrm;'                               + #10 +
    'layout(location=2) in vec2 aUV;'                                + #10 +
    'layout(location=3) in mat4 iModel;'                             + #10 +
    'layout(location=7) in vec4 iColor;'                             + #10 +
    'uniform mat4 uViewProj;'                                        + #10 +
    'out vec3 vNrm;'                                                 + #10 +
    'out vec3 vPos;'                                                 + #10 +
    'out vec2 vUV;'                                                  + #10 +
    'out vec4 vCol;'                                                 + #10 +
    'void main() {'                                                  + #10 +
    '  vec4 wp = iModel * vec4(aPos, 1.0);'                          + #10 +
    '  vPos = wp.xyz;'                                               + #10 +
    '  vNrm = mat3(iModel) * aNrm;'                                  + #10 +
    '  vUV = aUV;'                                                   + #10 +
    '  vCol = iColor;'                                               + #10 +
    '  gl_Position = uViewProj * wp;'                                + #10 +
    '}' + #10;

  FS_LIT =
    '#version 330 core'                                              + #10 +
    'in vec3 vNrm;'                                                  + #10 +
    'in vec3 vPos;'                                                  + #10 +
    'in vec2 vUV;'                                                   + #10 +
    'in vec4 vCol;'                                                  + #10 +
    'uniform vec3 uLightDir;'                                        + #10 +
    'uniform vec3 uCamPos;'                                          + #10 +
    'uniform vec3 uFogColor;'                                        + #10 +
    'uniform vec2 uFogParams;'                                       + #10 +
    'uniform vec3 uAmbient;'                                         + #10 +
    'out vec4 oColor;'                                               + #10 +
    ''                                                               + #10 +
    '// Процедурная клетка вместо текстуры: ноль обращений к памяти,'+ #10 +
    '// зато видно масштаб и скольжение тел.'                        + #10 +
    'float checker(vec2 uv) {'                                       + #10 +
    '  vec2 g = abs(fract(uv - 0.5) - 0.5) / fwidth(uv);'            + #10 +
    '  float l = min(min(g.x, g.y), 1.0);'                           + #10 +
    '  return mix(0.78, 1.0, l);'                                    + #10 +
    '}'                                                              + #10 +
    'void main() {'                                                  + #10 +
    '  vec3 N = normalize(vNrm);'                                    + #10 +
    '  vec3 L = normalize(-uLightDir);'                              + #10 +
    '  vec3 V = normalize(uCamPos - vPos);'                          + #10 +
    '  vec3 H = normalize(L + V);'                                   + #10 +
    '  float ndl = max(dot(N, L), 0.0);'                             + #10 +
    '  float spec = pow(max(dot(N, H), 0.0), 48.0) * 0.25;'          + #10 +
    '  // полусферическое окружение: небо сверху, отражённый свет снизу'+ #10 +
    '  float hemi = N.y * 0.5 + 0.5;'                                + #10 +
    '  vec3 amb = mix(uAmbient * 0.45, uAmbient, hemi);'             + #10 +
    '  // координаты клетки берём из мира по доминирующей оси нормали --'+ #10 +
    '  // сетка получается одного масштаба на всех телах'            + #10 +
    '  vec2 cuv = abs(N.y) > 0.5 ? vPos.xz'                          + #10 +
    '           : (abs(N.x) > 0.5 ? vPos.zy : vPos.xy);'             + #10 +
    '  vec3 base = vCol.rgb * checker(cuv);'                         + #10 +
    '  vec3 col = base * (amb + ndl) + vec3(spec) * ndl;'            + #10 +
    '  float d = length(uCamPos - vPos);'                            + #10 +
    '  float fog = clamp((d - uFogParams.x) /'                       + #10 +
    '                    (uFogParams.y - uFogParams.x), 0.0, 1.0);'  + #10 +
    '  col = mix(col, uFogColor, fog);'                              + #10 +
    '  // гамма-коррекция в конце кадра'                             + #10 +
    '  oColor = vec4(pow(col, vec3(1.0 / 2.2)), vCol.a);'            + #10 +
    '}' + #10;

  VS_LINE =
    '#version 330 core'                                              + #10 +
    'layout(location=0) in vec3 aPos;'                               + #10 +
    'layout(location=1) in vec3 aCol;'                               + #10 +
    'uniform mat4 uViewProj;'                                        + #10 +
    'out vec3 vCol;'                                                 + #10 +
    'void main() {'                                                  + #10 +
    '  vCol = aCol;'                                                 + #10 +
    '  gl_Position = uViewProj * vec4(aPos, 1.0);'                   + #10 +
    '}' + #10;

  FS_LINE =
    '#version 330 core'                                              + #10 +
    'in vec3 vCol;'                                                  + #10 +
    'out vec4 oColor;'                                               + #10 +
    'void main() { oColor = vec4(vCol, 1.0); }' + #10;

type
  TLineVert = record
    x, y, z: Single;
    r, g, b: Single;
  end;

var
  g_lines   : array[0..MAX_DEBUG_LINES * 2 - 1] of TLineVert;
  g_nlines  : Integer = 0;
  g_line_vao: GLuint = 0;
  g_line_vbo: GLuint = 0;

{ =========================================================================
  Шейдеры
  ========================================================================= }

function compile_stage(kind: GLenum; const src: string): GLuint;
var
  status, loglen: GLint;
  log: array[0..4095] of Char;
  p: PChar;
begin
  Result := glCreateShader(kind);
  p := PChar(src);
  glShaderSource(Result, 1, @p, nil);
  glCompileShader(Result);
  glGetShaderiv(Result, GL_COMPILE_STATUS, @status);
  if status = GL_FALSE then
  begin
    glGetShaderInfoLog(Result, SizeOf(log), @loglen, @log[0]);
    WriteLn('[shader] ошибка компиляции:');
    WriteLn(PChar(@log[0]));
    glDeleteShader(Result);
    Result := 0;
  end;
end;

function shader_build(const vs, fs: string): TShaderProgram;
var
  v, f: GLuint;
  status, loglen: GLint;
  log: array[0..4095] of Char;
begin
  FillChar(Result, SizeOf(Result), 0);
  v := compile_stage(GL_VERTEX_SHADER, vs);
  f := compile_stage(GL_FRAGMENT_SHADER, fs);
  if (v = 0) or (f = 0) then Exit;

  Result.id := glCreateProgram();
  glAttachShader(Result.id, v);
  glAttachShader(Result.id, f);
  glLinkProgram(Result.id);
  glGetProgramiv(Result.id, GL_LINK_STATUS, @status);
  if status = GL_FALSE then
  begin
    glGetProgramInfoLog(Result.id, SizeOf(log), @loglen, @log[0]);
    WriteLn('[shader] ошибка компоновки:');
    WriteLn(PChar(@log[0]));
    glDeleteProgram(Result.id);
    Result.id := 0;
  end;
  glDeleteShader(v);
  glDeleteShader(f);

  if Result.id = 0 then Exit;
  Result.uViewProj  := glGetUniformLocation(Result.id, 'uViewProj');
  Result.uModel     := glGetUniformLocation(Result.id, 'uModel');
  Result.uColor     := glGetUniformLocation(Result.id, 'uColor');
  Result.uLightDir  := glGetUniformLocation(Result.id, 'uLightDir');
  Result.uCamPos    := glGetUniformLocation(Result.id, 'uCamPos');
  Result.uFogColor  := glGetUniformLocation(Result.id, 'uFogColor');
  Result.uFogParams := glGetUniformLocation(Result.id, 'uFogParams');
  Result.uAmbient   := glGetUniformLocation(Result.id, 'uAmbient');
  Result.uTime      := glGetUniformLocation(Result.id, 'uTime');
end;

function render_init: Boolean;
begin
  g_light_dir := v3_norm(v3(-0.45, -0.8, -0.35));
  g_fog_color := v3(0.52, 0.62, 0.74);

  g_prog_lit := shader_build(VS_LIT, FS_LIT);
  g_prog_line := shader_build(VS_LINE, FS_LINE);
  Result := (g_prog_lit.id <> 0) and (g_prog_line.id <> 0);
  if not Result then Exit;

  { Буфер линий -- один на всю программу, переписывается каждый кадр. }
  glGenVertexArrays(1, @g_line_vao);
  glBindVertexArray(g_line_vao);
  glGenBuffers(1, @g_line_vbo);
  glBindBuffer(GL_ARRAY_BUFFER, g_line_vbo);
  glBufferData(GL_ARRAY_BUFFER, SizeOf(g_lines), nil, GL_STREAM_DRAW);
  glEnableVertexAttribArray(0);
  glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, SizeOf(TLineVert), Pointer(0));
  glEnableVertexAttribArray(1);
  glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, SizeOf(TLineVert), Pointer(12));
  glBindVertexArray(0);

  glEnable(GL_DEPTH_TEST);
  glDepthFunc(GL_LEQUAL);
  glEnable(GL_CULL_FACE);
  glCullFace(GL_BACK);
  glFrontFace(GL_CCW);
end;

procedure render_shutdown;
begin
  if g_line_vbo <> 0 then glDeleteBuffers(1, @g_line_vbo);
  if g_line_vao <> 0 then glDeleteVertexArrays(1, @g_line_vao);
  if g_prog_lit.id <> 0 then glDeleteProgram(g_prog_lit.id);
  if g_prog_line.id <> 0 then glDeleteProgram(g_prog_line.id);
end;

{ =========================================================================
  Кадр
  ========================================================================= }

procedure render_begin(const c: TCamera);
begin
  glClearColor(g_fog_color.x, g_fog_color.y, g_fog_color.z, 1.0);
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT);
  glEnable(GL_DEPTH_TEST);
  glDepthMask(GL_TRUE);
  glEnable(GL_CULL_FACE);
end;

procedure render_lit_begin(const c: TCamera);
begin
  glUseProgram(g_prog_lit.id);
  glUniformMatrix4fv(g_prog_lit.uViewProj, 1, GL_FALSE, @c.viewproj.m[0]);
  glUniform3f(g_prog_lit.uLightDir, g_light_dir.x, g_light_dir.y, g_light_dir.z);
  glUniform3f(g_prog_lit.uCamPos, c.pos.x, c.pos.y, c.pos.z);
  glUniform3f(g_prog_lit.uFogColor, g_fog_color.x, g_fog_color.y, g_fog_color.z);
  glUniform2f(g_prog_lit.uFogParams, g_fog_near, g_fog_far);
  glUniform3f(g_prog_lit.uAmbient, 0.30, 0.34, 0.42);
end;

procedure render_draw_batch(var m: TMesh; const inst: array of TInstance;
                            count: Integer);
begin
  if count <= 0 then Exit;
  mesh_update_instances(m, inst, count);
  mesh_draw_instanced(m, count);
end;

{ =========================================================================
  Отладочные линии
  ========================================================================= }

procedure dbg_clear;
begin
  g_nlines := 0;
end;

procedure dbg_line(const a, b: TVec3; const col: TVec3);
begin
  if g_nlines + 2 > MAX_DEBUG_LINES * 2 then Exit;
  g_lines[g_nlines].x := a.x; g_lines[g_nlines].y := a.y; g_lines[g_nlines].z := a.z;
  g_lines[g_nlines].r := col.x; g_lines[g_nlines].g := col.y; g_lines[g_nlines].b := col.z;
  Inc(g_nlines);
  g_lines[g_nlines].x := b.x; g_lines[g_nlines].y := b.y; g_lines[g_nlines].z := b.z;
  g_lines[g_nlines].r := col.x; g_lines[g_nlines].g := col.y; g_lines[g_nlines].b := col.z;
  Inc(g_nlines);
end;

procedure dbg_aabb(const box: TAABB; const col: TVec3);
var
  c: array[0..7] of TVec3;
  i: Integer;
  e: array[0..11, 0..1] of Integer = (
    (0,1),(1,3),(3,2),(2,0),
    (4,5),(5,7),(7,6),(6,4),
    (0,4),(1,5),(2,6),(3,7));
begin
  for i := 0 to 7 do
  begin
    if (i and 1) <> 0 then c[i].x := box.mx.x else c[i].x := box.mn.x;
    if (i and 2) <> 0 then c[i].y := box.mx.y else c[i].y := box.mn.y;
    if (i and 4) <> 0 then c[i].z := box.mx.z else c[i].z := box.mn.z;
  end;
  for i := 0 to 11 do
    dbg_line(c[e[i, 0]], c[e[i, 1]], col);
end;

procedure dbg_cross(const p: TVec3; size: Single; const col: TVec3);
begin
  dbg_line(v3(p.x - size, p.y, p.z), v3(p.x + size, p.y, p.z), col);
  dbg_line(v3(p.x, p.y - size, p.z), v3(p.x, p.y + size, p.z), col);
  dbg_line(v3(p.x, p.y, p.z - size), v3(p.x, p.y, p.z + size), col);
end;

procedure dbg_flush(const c: TCamera);
begin
  if g_nlines = 0 then Exit;
  glUseProgram(g_prog_line.id);
  glUniformMatrix4fv(g_prog_line.uViewProj, 1, GL_FALSE, @c.viewproj.m[0]);
  glBindVertexArray(g_line_vao);
  glBindBuffer(GL_ARRAY_BUFFER, g_line_vbo);
  glBufferData(GL_ARRAY_BUFFER, SizeOf(g_lines), nil, GL_STREAM_DRAW);
  glBufferSubData(GL_ARRAY_BUFFER, 0, g_nlines * SizeOf(TLineVert), @g_lines[0]);
  glDisable(GL_CULL_FACE);
  glDrawArrays(GL_LINES, 0, g_nlines);
  glEnable(GL_CULL_FACE);
end;

end.
