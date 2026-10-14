// Export only the selected, already-visible cells. Neutralize spreadsheet formulas.
export function csvCell(value) {
  let text = String(value)
  if (/^[\s]*[=+@-]/.test(text) || /^[\t\r\n]/.test(text)) text = `'${text}`
  return `"${text.replaceAll('"', '""')}"`
}

function cellText(cell) {
  const copy = cell.cloneNode(true)
  copy.querySelectorAll("button, form, svg, [hidden], .d-none, input[type=hidden]").forEach(node => node.remove())
  copy.querySelectorAll("input, textarea, select").forEach(field => {
    const text = field.tagName === "SELECT" ? field.selectedOptions[0]?.textContent : field.value
    field.replaceWith(document.createTextNode(text || ""))
  })
  return copy.textContent.replace(/\s+/g, " ").trim()
}

export function selectedCsv(table, rows) {
  const headers = table.tHead?.rows[0]
  const hasHeaders = headers && Array.from(headers.cells).some(cell => cellText(cell))
  const columns = Array.from(rows[0].cells).map((cell, index) => index)
    .filter(index => !rows[0].cells[index].classList.contains("bulk-select-cell"))
    .filter(index => !hasHeaders || (headers.cells[index] && cellText(headers.cells[index])))
  const lines = rows.map(row => columns.map(index => cellText(row.cells[index])))
  if (hasHeaders) lines.unshift(columns.map(index => cellText(headers.cells[index])))
  return lines.map(line => line.map(csvCell).join(",")).join("\r\n")
}
