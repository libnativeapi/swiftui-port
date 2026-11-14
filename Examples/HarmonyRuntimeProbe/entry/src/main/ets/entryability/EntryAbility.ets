import { UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import swiftProbe from 'libswiftprobe.so';

export default class EntryAbility extends UIAbility {
  private gallery: boolean = false;

  onCreate(want: Want): void {
    this.gallery = want.parameters?.['gallery'] === 'true';
    if (this.gallery) return;
    try {
      const first = swiftProbe.run(7);
      const second = swiftProbe.run(11);
      const status = first === 217 && second === 225 ? 'PASS' : 'FAIL';
      const result = `SWIFT_RUNTIME_PROBE ${status} values=${first},${second}`;
      AppStorage.setOrCreate('probeResult', result);
      hilog.info(0x0000, 'SwiftRuntimeProbe', '%{public}s', result);
      const foundation = swiftProbe.foundation();
      this.report('FOUNDATION', foundation, 42);
      const initial = swiftProbe.render();
      const count = swiftProbe.tap();
      this.report('RENDERER', initial === 0 ? count : initial, 1);
      swiftProbe.concurrency((value: number): void => {
        this.report('CONCURRENCY', value, 42);
      });
    } catch (error) {
      const result = `SWIFT_RUNTIME_PROBE FAIL ${error}`;
      AppStorage.setOrCreate('probeResult', result);
      hilog.error(0x0000, 'SwiftRuntimeProbe', '%{public}s', result);
    }
  }

  private report(name: string, value: number, expected: number): void {
    const status = value === expected ? 'PASS' : 'FAIL';
    const result = `SWIFT_${name}_PROBE ${status} value=${value}`;
    AppStorage.setOrCreate(name, result);
    hilog.info(0x0000, 'SwiftRuntimeProbe', '%{public}s', result);
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    stage.loadContent(this.gallery ? 'pages/Gallery' : 'pages/Index').catch((error: Error) => {
      hilog.error(0x0000, 'SwiftRuntimeProbe', 'Could not load probe page: %{public}s', error.message);
    });
  }
}
