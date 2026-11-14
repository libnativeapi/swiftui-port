import { NodeContent } from '@kit.ArkUI';
import swiftProbe from 'libswiftprobe.so';

@Entry
@Component
struct Index {
  @StorageLink('probeResult') result: string = 'Waiting for Swift runtime';
  @StorageLink('FOUNDATION') foundation: string = 'Waiting for Foundation';
  @StorageLink('RENDERER') renderer: string = 'Waiting for SwiftUIRuntime';
  @StorageLink('CONCURRENCY') concurrency: string = 'Waiting for Swift concurrency';
  private content: NodeContent = new NodeContent();

  aboutToAppear(): void {
    swiftProbe.attach(this.content);
  }

  aboutToDisappear(): void {
    swiftProbe.detach();
  }

  build() {
    Column({ space: 12 }) {
      Text('Swift Runtime Probe').fontSize(24)
      Text(this.result).fontSize(16)
      Text(this.foundation)
      Text(this.renderer)
      Text(this.concurrency)
      ContentSlot(this.content)
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
  }
}
