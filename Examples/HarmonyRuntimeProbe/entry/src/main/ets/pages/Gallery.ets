import { LengthMetrics, PathShape } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import swiftProbe from 'libswiftprobe.so';

interface GalleryNode {
  id: number;
  kind: string;
  x: number;
  y: number;
  width: number;
  height: number;
  text: string;
  label: string;
  placeholder: string;
  image: string;
  fontSize: number;
  fontWeight: number;
  fontFamily: string;
  textAlignment: string;
  lineSpacing: number;
  tracking: number;
  underline: boolean;
  lineLimit: number;
  path: string;
  clipPath?: string;
  rotation: number;
  scaleX: number;
  scaleY: number;
  dash: number[];
  foreground?: number;
  background?: number;
  border?: number;
  borderWidth: number;
  radius: number;
  opacity: number;
  clip: boolean;
  scrollIndicators: boolean;
  scrollDirection: string;
  selected: boolean;
  enabled: boolean;
  hitTesting: boolean;
  children: GalleryNode[];
}

@Observed
class GalleryModel {
  snapshot: GalleryNode;
  children: GalleryModel[];

  constructor(snapshot: GalleryNode) {
    this.snapshot = snapshot;
    this.children = snapshot.children.map((child: GalleryNode) => new GalleryModel(child));
  }

  update(snapshot: GalleryNode): void {
    const previous = new Map<number, GalleryModel>();
    this.children.forEach((child: GalleryModel) => previous.set(child.snapshot.id, child));
    this.snapshot = snapshot;
    const next = snapshot.children.map((child: GalleryNode) => {
      const retained = previous.get(child.id);
      if (!retained) return new GalleryModel(child);
      retained.update(child);
      return retained;
    });
    if (next.length !== this.children.length ||
      next.some((child: GalleryModel, index: number) => child !== this.children[index])) {
      this.children = next;
    }
  }
}

@Component
struct GalleryElement {
  @ObjectLink model: GalleryModel;
  @Prop parentX: number = 0;
  @Prop parentY: number = 0;
  @Prop parentOpacity: number = 1;

  private scroller: Scroller = new Scroller();

  private color(value: number | undefined, fallback: string): string {
    return value === undefined ? fallback : '#' + value.toString(16).padStart(8, '0');
  }

  private action(event: number): void {
    if (this.model.snapshot.enabled && this.model.snapshot.hitTesting) {
      swiftProbe.galleryEvent(this.model.snapshot.id, event, '');
    }
  }

  private makeClipShape(path: string | undefined): PathShape | undefined {
    return path ? new PathShape({ commands: path }) : undefined;
  }

  @Builder
  private children() {
    ForEach(this.model.children, (child: GalleryModel) => {
      GalleryElement({
        model: child,
        parentX: this.model.snapshot.x, parentY: this.model.snapshot.y, parentOpacity: this.model.snapshot.opacity
      })
    }, (child: GalleryModel) => String(child.snapshot.id))
  }

  @Builder
  private content() {
    if (this.model.snapshot.kind === 'text') {
      Text(this.model.snapshot.text)
        .fontSize(this.model.snapshot.fontSize + 'vp')
        .fontWeight(this.model.snapshot.fontWeight)
        .fontFamily(this.model.snapshot.fontFamily)
        .fontColor(this.color(this.model.snapshot.foreground, '#ff000000'))
        .textAlign(this.model.snapshot.textAlignment === 'center' ? TextAlign.Center :
          this.model.snapshot.textAlignment === 'end' ? TextAlign.End : TextAlign.Start)
        .lineSpacing(LengthMetrics.vp(this.model.snapshot.lineSpacing))
        .letterSpacing(this.model.snapshot.tracking + 'vp')
        .decoration({ type: this.model.snapshot.underline ? TextDecorationType.Underline : TextDecorationType.None })
        .maxLines(this.model.snapshot.lineLimit > 0 ? this.model.snapshot.lineLimit : 1000)
        .width('100%')
        .height('100%')
        .align(Alignment.TopStart)
        .hitTestBehavior(HitTestMode.None)
    } else if (this.model.snapshot.kind === 'image' && this.model.snapshot.image.startsWith('fluent/')) {
      Image('resource://RAWFILE/' + this.model.snapshot.image)
        .objectFit(ImageFit.Contain)
        .fillColor(this.color(this.model.snapshot.foreground, '#ff000000'))
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
    } else if (this.model.snapshot.kind === 'path') {
      Path().commands(this.model.snapshot.path)
        .width('100%')
        .height('100%')
        .fill(this.color(this.model.snapshot.background, '#00000000'))
        .stroke(this.color(this.model.snapshot.border, '#00000000'))
        .strokeWidth(this.model.snapshot.borderWidth)
        .strokeDashArray(this.model.snapshot.dash)
        .hitTestBehavior(HitTestMode.None)
    } else if (this.model.snapshot.kind === 'editor') {
      TextInput({ text: this.model.snapshot.text, placeholder: this.model.snapshot.placeholder })
        .backgroundColor(Color.Transparent)
        .padding(0)
        .borderRadius(0)
        .fontSize(this.model.snapshot.fontSize)
        .fontColor(this.color(this.model.snapshot.foreground, '#ff000000'))
        .width('100%')
        .height('100%')
        .onChange((value: string) => {
          if (value !== this.model.snapshot.text) swiftProbe.galleryEvent(this.model.snapshot.id, 7, value);
        })
    } else if (this.model.snapshot.kind === 'scroll') {
      Scroll(this.scroller) {
        Stack({ alignContent: Alignment.TopStart }) {
          this.children()
        }
        .width(this.model.snapshot.children[0]?.width ?? this.model.snapshot.width)
        .height(this.model.snapshot.children[0]?.height ?? this.model.snapshot.height)
      }
      .width('100%')
      .height('100%')
      .scrollable(this.model.snapshot.scrollDirection === 'both' ? ScrollDirection.FREE :
        this.model.snapshot.scrollDirection === 'horizontal' ? ScrollDirection.Horizontal : ScrollDirection.Vertical)
      .scrollBar(this.model.snapshot.scrollIndicators ? BarState.Auto : BarState.Off)
    } else if (this.model.snapshot.kind === 'button' && this.model.snapshot.children.length === 0) {
      Text(this.model.snapshot.text)
        .fontSize(this.model.snapshot.fontSize + 'vp')
        .fontWeight(this.model.snapshot.fontWeight)
        .fontFamily(this.model.snapshot.fontFamily)
        .fontColor(this.color(this.model.snapshot.foreground, '#ff000000'))
        .width('100%')
        .height('100%')
        .align(Alignment.Center)
        .hitTestBehavior(HitTestMode.None)
    } else {
      this.children()
    }
  }

  @Builder
  private visual() {
    if (this.model.snapshot.kind === 'button' && this.model.snapshot.hitTesting) {
      Button({ type: ButtonType.Normal, stateEffect: false }) {
        Stack({ alignContent: Alignment.TopStart }) {
          this.content()
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      .padding(0)
      .borderRadius(0)
      .backgroundColor(Color.Transparent)
      .hoverEffect(HoverEffect.None)
      .accessibilityText(this.model.snapshot.label)
      .accessibilitySelected(this.model.snapshot.selected)
      .id(this.model.snapshot.label.length > 0 ? 'swift-action-' + this.model.snapshot.label : 'swift-node-' + String(this.model.snapshot.id))
      .onClick(() => this.action(1))
      .onHover((hovered: boolean) => this.action(hovered ? 2 : 3))
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) this.action(4);
        if (event.type === TouchType.Up || event.type === TouchType.Cancel) this.action(5);
      })
      .onFocus(() => this.action(8))
      .onBlur(() => this.action(9))
    } else {
      this.content()
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.visual()
    }
    .width(this.model.snapshot.width)
    .height(this.model.snapshot.height)
    .position({ x: this.model.snapshot.x - this.parentX, y: this.model.snapshot.y - this.parentY })
    .backgroundColor(this.model.snapshot.kind === 'path' ? '#00000000' : this.color(this.model.snapshot.background, '#00000000'))
    .border({ width: this.model.snapshot.kind === 'path' ? 0 : this.model.snapshot.borderWidth, radius: this.model.snapshot.radius,
      color: this.color(this.model.snapshot.border, '#00000000') })
    .clip(this.model.snapshot.clip && !this.model.snapshot.clipPath)
    .clipShape(this.makeClipShape(this.model.snapshot.clipPath))
    .rotate({ angle: this.model.snapshot.rotation })
    .scale({ x: this.model.snapshot.scaleX, y: this.model.snapshot.scaleY })
    .opacity(this.parentOpacity > 0 ? Math.min(1, this.model.snapshot.opacity / this.parentOpacity) : 0)
    .enabled(this.model.snapshot.enabled)
    .hitTestBehavior(this.model.snapshot.hitTesting ? HitTestMode.Transparent : HitTestMode.None)
  }
}

@Entry
@Component
struct Gallery {
  @State private tree: GalleryModel | undefined = undefined;
  private mounted: boolean = false;

  aboutToDisappear(): void {
    if (this.mounted) swiftProbe.unmountGallery();
    this.mounted = false;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.tree) {
        GalleryElement({ model: this.tree })
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_old: Area, area: Area) => {
      const width = Number(area.width);
      const height = Number(area.height);
      if (width <= 0 || height <= 0) return;
      if (this.mounted) {
        swiftProbe.resizeGallery(width, height);
      } else {
        this.mounted = true;
        swiftProbe.mountGallery((json: string) => {
          const snapshot = JSON.parse(json) as GalleryNode;
          if (this.tree && this.tree.snapshot.id === snapshot.id) {
            this.tree.update(snapshot);
          } else {
            this.tree = new GalleryModel(snapshot);
            hilog.info(0x0000, 'SwiftRuntimeProbe', 'SWIFT_GALLERY_PROBE mounted');
          }
        }, width, height, this.getUIContext().vp2px(1));
      }
    })
  }
}
