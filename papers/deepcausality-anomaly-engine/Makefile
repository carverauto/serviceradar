DOC      := main
TEXBIN   := /Library/TeX/texbin
LATEXMK  := $(TEXBIN)/latexmk
LMKFLAGS := -pdf -interaction=nonstopmode -halt-on-error -file-line-error

.PHONY: all clean watch view
all: $(DOC).pdf

$(DOC).pdf: $(DOC).tex $(wildcard sections/*.tex) references.bib
	$(LATEXMK) $(LMKFLAGS) $(DOC).tex

watch:
	$(LATEXMK) $(LMKFLAGS) -pvc $(DOC).tex

view: all
	open $(DOC).pdf

clean:
	$(TEXBIN)/latexmk -C $(DOC).tex
	rm -f $(DOC).bbl $(DOC).run.xml
