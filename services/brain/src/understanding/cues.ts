// App and host cues for stand-in apps, from masked window chrome and URL-bar text.
export interface Cue {
  appBundleId?: string;
  appName?: string;
  host?: string;
}

export function isStandInApp(_bundleId: string, _appName: string): boolean {
  throw new Error("not implemented");
}

export function cueOf(_text: string): Cue {
  throw new Error("not implemented");
}
