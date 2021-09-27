all: presentation.pdf

%.pdf: %.md
	pandoc -t beamer+smart --pdf-engine xelatex --syntax-definition kotlin.xml --highlight-style highlight.theme $< -o $@

%.tex: %.md
	pandoc --standalone -t beamer+smart --pdf-engine xelatex --syntax-definition kotlin.xml --highlight-style highlight.theme $< -o $@

clean:
	rm -f presentation.pdf
