// Amount fields take digits and one decimal point, nothing else. Keys that would add anything else
// do nothing; pasted text keeps only those, a comma (as some keyboards type it) becoming the point.

export function blockLetters(event: InputEvent) {
  if (event.data && /[^\d.,]/.test(event.data)) event.preventDefault();
}

// Cleans what's in the field, keeping the caret where it was, and returns the amount it shows.
export function cleanAmount(input: HTMLInputElement): string {
  let cleaned = input.value.replace(/,/g, '.').replace(/[^\d.]/g, '');
  const point = cleaned.indexOf('.');
  if (point !== -1) cleaned = cleaned.slice(0, point + 1) + cleaned.slice(point + 1).replace(/\./g, '');
  if (cleaned !== input.value) {
    const caret = Math.max(0, (input.selectionStart ?? cleaned.length) - (input.value.length - cleaned.length));
    input.value = cleaned;
    input.setSelectionRange(caret, caret);
  }
  return cleaned;
}
