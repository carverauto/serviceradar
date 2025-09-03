declare module 'lodash.set' {
  function set<T>(object: T, path: string | (string | number)[], value: unknown): T;
  export = set;
}