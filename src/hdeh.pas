{ ============================================================================
  hdeh - the whole engine in one "uses" clause.

      uses hdeh;

  brings in the math, image, mesh, scene, rasterizer, shadow and engine
  units plus the terminal display back end.  The SDL back end lives in
  hdeh_sdl2 and is deliberately *not* pulled in here: it links against
  libSDL2, and a terminal only program should not need that library.
  ============================================================================ }
unit hdeh;
{$mode objfpc}{$H+}

interface

uses
  hdeh_math,
  hdeh_image,
  hdeh_mesh,
  hdeh_scene,
  hdeh_raster,
  hdeh_shadow,
  hdeh_display,
  hdeh_engine,
  hdeh_console;

implementation

end.
