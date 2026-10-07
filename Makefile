# ============================================================
#  Сборка 3D-движка на Free Pascal
#  Требуется: fpc >= 3.2, установленная библиотека GLFW 3.3
# ============================================================

FPC      ?= fpc
OUT      ?= build
BIN      ?= $(OUT)/engine3d
SRC      := src/main.pas

# -O3        агрессивная оптимизация
# -CpCOREAVX2 целевой набор инструкций современного процессора
# -OoFASTMATH разрешить переупорядочивание вещественной арифметики
# -Sv        поддержка векторных типов
# -XX -CX    умная компоновка, выкидывает неиспользуемый код
FLAGS    := -O3 -OoFASTMATH -CpCOREAVX2 -Xs -XX -CX -Sv \
            -Fu src -FU $(OUT)/units -FE $(OUT) -o$(notdir $(BIN))

DEBUGFLAGS := -O1 -g -gl -Criot -Fu src -FU $(OUT)/units -FE $(OUT) -o$(notdir $(BIN))

all: dirs
	$(FPC) $(FLAGS) $(SRC)

debug: dirs
	$(FPC) $(DEBUGFLAGS) $(SRC)

# Сборка без AVX2 -- для старых процессоров и виртуалок
portable: dirs
	$(FPC) -O3 -Xs -XX -CX -Fu src -FU $(OUT)/units -FE $(OUT) -o$(notdir $(BIN)) $(SRC)

dirs:
	@mkdir -p $(OUT)/units

run: all
	./$(BIN)

clean:
	rm -rf $(OUT)

.PHONY: all debug portable dirs run clean
