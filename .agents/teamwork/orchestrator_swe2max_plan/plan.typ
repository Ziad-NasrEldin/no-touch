#set page(
  paper: "a4",
  margin: (x: 19mm, top: 18mm, bottom: 19mm),
  footer: context [
    #set text(size: 8pt, fill: luma(90))
    SWE 2 Max orchestration · For review #h(1fr) #counter(page).display("1 / 1", both: true)
  ],
)
#set text(font: "Helvetica Neue", size: 10pt)
#set par(justify: false, leading: 0.58em)
#set heading(numbering: none)
#show heading.where(level: 1): set text(size: 14pt)
#show heading.where(level: 1): set block(above: 1.2em, below: 0.65em)
#set list(indent: 0pt, body-indent: 12pt, spacing: 0.6em)
#set enum(indent: 0pt, body-indent: 19pt, spacing: 0.55em)

#let rich(s) = {
  let pieces = s.split("**")
  for (i, piece) in pieces.enumerate() {
    if calc.rem(i, 2) == 1 { strong(piece) } else { text(piece) }
  }
}

#let blocks = json("plan-content.json")
#align(left)[
  #text(size: 22pt, weight: "bold")[SWE 2 Max orchestration plan]
  #v(5pt)
  #text(size: 13pt, fill: luma(65))[Apple Watch recorder · Local Gulf Arabic AI]
]
#v(10pt)
#block(fill: luma(241), inset: 11pt, width: 100%, radius: 3pt)[
  #text(weight: "bold")[PREPARED FOR REVIEW · NO WORKERS LAUNCHED]
  #v(4pt)
  Eight planned worker tasks · Three workers maximum at once
  #linebreak()
  No unit or integration tests · Build-only checks and manual device trials
  #v(5pt)
  #text(size: 9pt)[Exact standalone SWE 2 Max selection is unverified. Fusion/SWE-2 Flash Max entries are not selected as substitutes. Target repository and hardware evidence are pending.]
]
#v(5pt)

#let numbering = 0
#for b in blocks {
  if b.kind == "title" {
    // Rendered above.
  } else if b.kind == "heading" {
    heading(level: 1, text(b.text))
  } else if b.kind == "number" {
    numbering += 1
    enum(start: numbering, rich(b.text))
  } else if b.kind == "bullet" {
    list(rich(b.text))
  } else {
    par(rich(b.text))
    v(3pt)
  }
}
