#set page(
  paper: "a4",
  margin: (x: 19mm, top: 18mm, bottom: 19mm),
  footer: context [
    #set text(size: 8pt, fill: luma(90))
    Apple Watch recorder · Draft for review #h(1fr) #counter(page).display("1 / 1", both: true)
  ],
)
#set text(font: "Helvetica Neue", size: 10pt)
#set par(justify: false, leading: 0.58em)
#set heading(numbering: none)
#show heading.where(level: 1): set text(size: 14pt)
#show heading.where(level: 1): set block(above: 1.2em, below: 0.65em)
#set list(indent: 0pt, body-indent: 12pt, spacing: 0.6em)
#set enum(indent: 0pt, body-indent: 19pt, spacing: 0.55em)

#let linked(s) = {
  let cursor = 0
  for m in s.matches(regex("\\[([^\\]]+)\\]\\(([^\\s]+)\\)")) {
    text(s.slice(cursor, m.start))
    link(m.captures.at(1), underline(text(m.captures.at(0))))
    cursor = m.end
  }
  text(s.slice(cursor))
}

#let rich(s) = {
  let pieces = s.split("**")
  for (i, piece) in pieces.enumerate() {
    if calc.rem(i, 2) == 1 { strong(linked(piece)) } else { linked(piece) }
  }
}

#let blocks = json("spec-content.json")
#align(left)[
  #text(size: 22pt, weight: "bold")[All-day Apple Watch recorder]
  #v(5pt)
  #text(size: 13pt, fill: luma(65))[Local Arabic conversation intelligence]
]
#v(10pt)
#block(fill: luma(241), inset: 11pt, width: 100%, radius: 3pt)[
  #text(weight: "bold")[DRAFT · FOR REVIEW · NOT PUBLISHED]
  #v(4pt)
  iPhone 14 Pro Max · Apple Watch likely Series 6
  #linebreak()
  Saudi/Gulf Arabic with occasional English · Start once, capture throughout the day
  #v(5pt)
  #text(size: 9pt)[Verification boundary accepted. Do not write or run unit or integration tests. Model choices are proposed; no device endurance or accuracy results exist. Tracker setup is pending.]
]
#v(5pt)

#let numbering = 0
#for b in blocks {
  if b.kind == "title" {
    // Rendered in the title block above.
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
