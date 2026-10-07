# ============================================================
#  Сборка 3D-движка на Free Pascal
#  Требуется: fpc >= 3.2 и GLFW 3.3 вместе с пакетом разработчика
#  (Debian/Ubuntu: fpc libglfw3-dev, macOS: brew install fpc glfw)
#
#  Свой компилятор можно подсунуть так:
#      make FPC=/путь/к/ppcx64 RTL=/путь/к/units/x86_64-linux
# ============================================================

FPC      ?= fpc
OUT      ?= build
BIN      := $(OUT)/engine3d
TESTBIN  := $(OUT)/test_physics
RTESTBIN := $(OUT)/test_render
PREVBIN  := $(OUT)/render_preview
SRC      := src/main.pas

# Если указан RTL -- добавляем пути к модулям RTL вручную
# (нужно, когда компилятор запускается не из установленного окружения).
ifneq ($(RTL),)
RTLFLAGS := -Fu$(RTL)/rtl -Fu$(RTL)/rtl-objpas -Fu$(RTL)/rtl-extra -Fu$(RTL)/rtl-console
endif

# -O3         агрессивная оптимизация
# -OoFASTMATH разрешить переупорядочивание вещественной арифметики
# -CpCOREAVX2 целевой набор инструкций современного процессора
# -Xs         убрать символы из бинарника
# -XX -CX     умная компоновка: выкидывает неиспользуемый код
COMMON   := $(RTLFLAGS) -Fusrc -FU$(OUT)/units -FE$(OUT)
FLAGS    := -O3 -OoFASTMATH -CpCOREAVX2 -Xs -XX -CX $(COMMON)
PORTFLAGS:= -O3 -Xs -XX -CX $(COMMON)
DBGFLAGS := -O1 -g -gl -Criot $(COMMON)

all: dirs
	$(FPC) $(FLAGS) -oengine3d $(SRC)

# Сборка без AVX2 -- для старых процессоров и виртуальных машин
portable: dirs
	$(FPC) $(PORTFLAGS) -oengine3d $(SRC)

debug: dirs
	$(FPC) $(DBGFLAGS) -oengine3d $(SRC)

# Тесты. Ни OpenGL, ни GLFW, ни дисплей для них не нужны.
test: test-physics test-render

test-physics: dirs
	$(FPC) -O3 $(RTLFLAGS) -Fusrc -FU$(OUT)/tunits -FE$(OUT) -otest_physics tests/test_physics.pas
	./$(TESTBIN)

test-render: dirs
	$(FPC) -O3 $(RTLFLAGS) -Fusrc -FU$(OUT)/tunits -FE$(OUT) -otest_render tests/test_render.pas
	./$(RTESTBIN)

# Кадр, нарисованный программным растеризатором: та же сцена, та же камера
# и та же модель освещения, что и в шейдерах, но без видеокарты.
preview: dirs
	$(FPC) -O3 $(RTLFLAGS) -Fusrc -FU$(OUT)/tunits -FE$(OUT) -orender_preview tests/render_preview.pas
	./$(PREVBIN)
	@python3 tools/bmp2png.py $(OUT)/preview.bmp $(OUT)/preview.png 2>/dev/null \
	  && echo "также сохранено: $(OUT)/preview.png" || true

dirs:
	@mkdir -p $(OUT)/units $(OUT)/tunits

run: all
	./$(BIN)

clean:
	rm -rf $(OUT)

.PHONY: all portable debug test test-physics test-render preview dirs run clean
