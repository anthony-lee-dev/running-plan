// Vite's `?raw` import gives a file's text. Lets tests read config without Node types.
declare module "*?raw" {
  const text: string;
  export default text;
}
