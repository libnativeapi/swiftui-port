import { NodeContent } from '@kit.ArkUI';

export const run: (seed: number) => number;
export const foundation: () => number;
export const concurrency: (callback: (value: number) => void) => void;
export const render: () => number;
export const tap: () => number;
export const attach: (content: NodeContent) => void;
export const detach: () => void;
export const mountGallery: (update: (tree: string) => void, width: number, height: number,
  pixelsPerPoint: number) => void;
export const resizeGallery: (width: number, height: number) => void;
export const galleryEvent: (id: number, event: number, text: string) => void;
export const unmountGallery: () => void;
