export const pace = (secPerKm: number): string => {
  const whole = Math.round(secPerKm); // round first, so 359.6 s reads 6:00 and never 5:60
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")}/km`;
};

export function clock(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}` : `${m}:${String(s).padStart(2, "0")}`;
}
