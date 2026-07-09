const emailRegex: RegExp = /^[^\s@]+@[^\s@]+\.[A-Za-z]{2,}$/;
const phoneRegex: RegExp = /^1[3-9]\d{9}$/;

export function isPhone(value: string): boolean {
  return phoneRegex.test(value);
}

export function isEmail(value: string): boolean {
  return emailRegex.test(value);
}

export function isPhoneOrEmail(value: string): boolean {
  return isPhone(value) || isEmail(value);
}
