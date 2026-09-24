import {
  abilityAccessCtrl,
  bundleManager,
  common,
  Permissions,
  PermissionRequestResult,
  Want
} from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { inputMethod, InputMethodSubtype } from '@kit.IMEKit';
import { SegmentedTabs } from '../keyboard/components/AileControls';
import { Log } from '../ime/Log';
import { popTransition } from '../keyboard/Motion';
import { WindowInsets } from '../entryability/WindowInsets';

const PASTEBOARD_PERMISSION: Permissions = 'ohos.permission.READ_PASTEBOARD';
// 设置应用按 uri 选择要打开的页面，set_input 正是输入法页面，system_and_updates 是它的上一层“系统”页
const SETTINGS_BUNDLE: string = 'com.huawei.hmos.settings';
const SETTINGS_ABILITY: string = 'com.huawei.hmos.settings.MainAbility';
const SETTINGS_INPUT_URI: string = 'set_input';
const SETTINGS_SYSTEM_URI: string = 'system_and_updates';
// “系统”页在设置应用的能力声明里登记过，可以按动作隐式发起，由系统挑出设置应用
const SETTINGS_ACTION: string = 'ohos.want.action.viewData';
// 跳转失败时提示系统里的位置
const SETTINGS_PATH_TIP: string = '请打开 设置 › 系统 › 输入法';
const TOAST_DURATION_MS: number = 2600;
const CARD_RADIUS_VP: number = 20;
// 窗口不窄于这个宽度时分左右两栏，与栅格默认的 lg 断点一致
const WIDE_WIDTH_VP: number = 840;
const NARROW_TEXT_HEIGHT_VP: number = 240;
// 每一步带一行说明，三行等高，完成以后标题居中
const STEP_ROW_HEIGHT_VP: number = 68;
// 右侧状态与按钮共用同一块胶囊区域，三行的文字与右边界因此各自对齐
const TRAILING_HEIGHT_VP: number = 32;
const TRAILING_PADDING_VP: number = 12;
const STEP_ROW_RIGHT_VP: number = 14;
// 分组标题右侧的状态文字与卡片内的状态文字对齐：行内边距加上胶囊内边距
const SECTION_STATUS_RIGHT_VP: number = STEP_ROW_RIGHT_VP + TRAILING_PADDING_VP;
// 系统栏之外再留出的页面上下边距
const PAGE_TOP_VP: number = 40;
const PAGE_BOTTOM_VP: number = 32;

enum SetupStep {
  ENABLE = 0,
  SWITCH = 1,
  CLIPBOARD = 2
}

const SETUP_STEPS: SetupStep[] = [SetupStep.ENABLE, SetupStep.SWITCH, SetupStep.CLIPBOARD];

// 试打区的输入框类型，用来查看键盘随输入框自动切换语言和页面。
// 密码框由系统安全键盘接管，第三方键盘不会出现，这里不提供
enum TryField {
  TEXT = 0,
  EMAIL = 1,
  NUMBER = 2
}

const TRY_TABS: string[] = ['文本', '邮箱', '数字'];
const TRY_CAPTIONS: string[] = ['', '自动切到英文', '直接打开数字键盘'];

enum GestureVisual {
  FLICK = 0,
  SPACE = 1,
  CLEAR = 2,
  MARK = 3,
  CLIP = 4,
  CANDIDATE = 5
}

interface Gesture {
  visual: GestureVisual;
  title: string;
  detail: string;
}

const GESTURES: Gesture[] = [
  { visual: GestureVisual.FLICK, title: '上滑字母', detail: '数字与符号' },
  { visual: GestureVisual.SPACE, title: '左右滑空格', detail: '移动光标' },
  { visual: GestureVisual.CLEAR, title: '上滑删除', detail: '清空，可撤销' },
  { visual: GestureVisual.MARK, title: '点 Aile 标志', detail: '表情、剪贴板与常用语' },
  { visual: GestureVisual.CLIP, title: '长按剪贴板', detail: '选字或存为常用语' },
  { visual: GestureVisual.CANDIDATE, title: '长按候选', detail: '删除学习记录' }
];

/**
 * 应用首页：顶部是标志与一句介绍，左栏是设置进度和手势速查，右栏是试打区。
 * 设置进度实时读取系统状态，从系统设置返回或切换输入法后自动刷新。
 * 横屏宽度下分为左右两栏，竖屏时上下排列。
 */
@Entry
@ComponentV2
struct WelcomePage {
  @Local imeEnabled: boolean = false;
  @Local imeCurrent: boolean = false;
  @Local clipboardGranted: boolean = false;
  @Local tryField: number = TryField.TEXT;
  @Local notes: string = '';
  // 两栏时右侧卡片与左栏等高，底边对齐
  @Local wide: boolean = true;
  @Local leftHeight: number = 0;
  // 窗口铺满全屏，页面背景延伸到状态栏与底部手势横条下方
  @Local insets: WindowInsets = WindowInsets.get();
  private version: string = '';
  private onImeChange = (property: inputMethod.InputMethodProperty, subtype: InputMethodSubtype): void => {
    this.refresh();
  };

  aboutToAppear(): void {
    try {
      this.version = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
    } catch (error) {
      this.version = '';
    }
    try {
      inputMethod.getSetting().on('imeChange', this.onImeChange);
    } catch (error) {
      // 监听失败时仍会在页面显示时刷新
    }
    this.refresh();
  }

  aboutToDisappear(): void {
    try {
      inputMethod.getSetting().off('imeChange', this.onImeChange);
    } catch (error) {
      // 页面销毁时忽略
    }
  }

  // 从系统设置返回时重新读取状态
  onPageShow(): void {
    this.refresh();
  }

  private context(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private refresh(): void {
    const context = this.context();
    const bundleName = context.abilityInfo.bundleName;
    try {
      const property = inputMethod.getCurrentInputMethod();
      this.imeCurrent = property !== undefined && property.name === bundleName;
    } catch (error) {
      this.imeCurrent = false;
    }
    inputMethod.getSetting().getInputMethods(true).then((list: inputMethod.InputMethodProperty[]) => {
      this.imeEnabled = this.imeCurrent || list.some((item: inputMethod.InputMethodProperty) => item.name === bundleName);
    }).catch((error: BusinessError) => {
      this.imeEnabled = this.imeCurrent;
    });
    try {
      const status = abilityAccessCtrl.createAtManager().checkAccessTokenSync(
        context.applicationInfo.accessTokenId, PASTEBOARD_PERMISSION);
      this.clipboardGranted = status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (error) {
      this.clipboardGranted = false;
    }
  }

  // 给出的界面属于某个已安装的输入法时，它是那个输入法自己的设置页，与这里要去的地方不同
  private isInputMethodBundle(bundleName: string): boolean {
    try {
      const list = inputMethod.getSetting().getAllInputMethodsSync();
      return list.some((item: inputMethod.InputMethodProperty) => item.name === bundleName);
    } catch (error) {
      return false;
    }
  }

  /**
   * 系统登记的输入法配置界面，正常情况下就是系统设置里的输入法页面，一步到位。
   * 返回值指向某个输入法自己的设置应用时按不可用处理，改走“系统”页。
   */
  private configuredImeSettings(): Want | undefined {
    try {
      const element = inputMethod.getSystemInputMethodConfigAbility();
      if (element.bundleName.length === 0 || this.isInputMethodBundle(element.bundleName)) {
        return undefined;
      }
      const want: Want = {
        bundleName: element.bundleName,
        moduleName: element.moduleName,
        abilityName: element.abilityName,
        uri: element.uri
      };
      return want;
    } catch (error) {
      return undefined;
    }
  }

  /**
   * 跳转目标按优先级排好：设置应用的输入法页面一步到位，其次是系统登记的输入法配置界面，
   * 最后是设置应用的“系统”页，输入法在这一页里面再点一次。
   */
  private imeSettingsWants(): Want[] {
    const list: Want[] = [];
    const direct: Want = {
      bundleName: SETTINGS_BUNDLE,
      abilityName: SETTINGS_ABILITY,
      uri: SETTINGS_INPUT_URI
    };
    list.push(direct);
    const configured = this.configuredImeSettings();
    if (configured !== undefined) {
      list.push(configured);
    }
    const fallback: Want = { action: SETTINGS_ACTION, uri: SETTINGS_SYSTEM_URI };
    list.push(fallback);
    return list;
  }

  // 逐个尝试，全部打不开时给出路径提示。回到本页时由 onPageShow 重新读取状态
  private startImeSettings(list: Want[], index: number): void {
    if (index >= list.length) {
      this.showSettingsPath();
      return;
    }
    try {
      this.context().startAbility(list[index]).catch((error: BusinessError) => {
        Log.warn(`open ime settings failed at ${index}, code ${error.code}`);
        this.startImeSettings(list, index + 1);
      });
    } catch (error) {
      const err = error as BusinessError;
      Log.warn(`start ime settings threw at ${index}, code ${err.code}`);
      this.startImeSettings(list, index + 1);
    }
  }

  private openImeSettings(): void {
    this.startImeSettings(this.imeSettingsWants(), 0);
  }

  // 系统没有给出跳转目标时，把路径说清楚，用户照着点也能到
  private showSettingsPath(): void {
    try {
      this.getUIContext().getPromptAction().showToast({
        message: SETTINGS_PATH_TIP,
        duration: TOAST_DURATION_MS
      });
    } catch (error) {
      // 提示失败时页面状态不变
    }
  }

  // 剪贴板读取权限只能从应用界面申请，输入法扩展与应用共用授权结果。曾经拒绝过时改为弹出设置授权框
  private requestClipboard(): void {
    const context = this.context();
    const manager = abilityAccessCtrl.createAtManager();
    manager.requestPermissionsFromUser(context, [PASTEBOARD_PERMISSION])
      .then((result: PermissionRequestResult) => {
        const granted = result.authResults.length > 0 && result.authResults[0] === 0;
        const shown = result.dialogShownResults === undefined || result.dialogShownResults[0];
        if (!granted && !shown) {
          return manager.requestPermissionOnSetting(context, [PASTEBOARD_PERMISSION]).then(() => {
            this.refresh();
          });
        }
        this.refresh();
        return Promise.resolve();
      })
      .catch((error: BusinessError) => {
        this.refresh();
      });
  }

  private allReady(): boolean {
    return this.imeEnabled && this.imeCurrent && this.clipboardGranted;
  }

  private stepDone(step: SetupStep): boolean {
    switch (step) {
      case SetupStep.ENABLE:
        return this.imeEnabled;
      case SetupStep.SWITCH:
        return this.imeCurrent;
      default:
        return this.clipboardGranted;
    }
  }

  private stepTitle(step: SetupStep): string {
    switch (step) {
      case SetupStep.ENABLE:
        return '启用 Aile';
      case SetupStep.SWITCH:
        return '设为默认输入法';
      default:
        return '读取剪贴板';
    }
  }

  // 未完成时说明要在系统页面里做什么，完成以后这一行收起
  private stepDetail(step: SetupStep): string {
    switch (step) {
      case SetupStep.ENABLE:
        return '在输入法管理里打开 Aile输入法';
      case SetupStep.SWITCH:
        return '把默认输入法选成 Aile输入法';
      default:
        return '让键盘里的剪贴板读到复制过的内容';
    }
  }

  private stepDoneText(step: SetupStep): string {
    switch (step) {
      case SetupStep.ENABLE:
        return '已启用';
      case SetupStep.SWITCH:
        return '使用中';
      default:
        return '已允许';
    }
  }

  // 前两步都落在系统的输入法设置页，剪贴板权限只能在应用内弹框申请
  private stepAction(step: SetupStep): string {
    return step === SetupStep.CLIPBOARD ? '允许' : '去设置';
  }

  // 默认输入法随时可能换走，这一步完成以后仍然保留一个能按的入口
  private stepStaysOpen(step: SetupStep): boolean {
    return step === SetupStep.SWITCH;
  }

  // 右侧可以按下的步骤：尚未完成的，以及完成后仍保留入口的默认输入法
  private stepActive(step: SetupStep): boolean {
    return !this.stepDone(step) || this.stepStaysOpen(step);
  }

  private stepTrailing(step: SetupStep): string {
    return this.stepDone(step) ? this.stepDoneText(step) : this.stepAction(step);
  }

  private runStep(step: SetupStep): void {
    if (step === SetupStep.CLIPBOARD) {
      this.requestClipboard();
    } else {
      this.openImeSettings();
    }
  }

  // ---------- 通用样式 ----------

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.app_text_secondary'))
      .padding({ left: 6 })
      .margin({ bottom: 10 })
  }

  @Styles
  pillNormal() {
    .opacity(1)
  }

  @Styles
  pillPressed() {
    .opacity(0.6)
  }

  // 状态文字与可按胶囊的尺寸完全相同，区别只有底色
  @Styles
  trailingSlot() {
    .height(TRAILING_HEIGHT_VP)
    .padding({ left: TRAILING_PADDING_VP, right: TRAILING_PADDING_VP })
    .borderRadius(TRAILING_HEIGHT_VP / 2)
  }

  // ---------- 顶部 ----------

  @Builder
  header() {
    Row({ space: 16 }) {
      Image($r('app.media.aile_mark'))
        .width(48)
        .height(48)
        .draggable(false)
      Column({ space: 4 }) {
        Text('Aile')
          .fontSize(32)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.app_text'))
        Text('为双手横握平板设计的分离式键盘')
          .fontSize(15)
          .fontColor($r('app.color.app_text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 6 })
  }

  // ---------- 设置 ----------

  // 状态与文字都在构建函数内按步骤读取，按值传入的参数不会随状态刷新
  @Builder
  stepIndicator(step: SetupStep) {
    Stack() {
      if (this.stepDone(step)) {
        Stack() {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(14)
            .fontColor([Color.White])
        }
        .width(26)
        .height(26)
        .borderRadius(13)
        .backgroundColor($r('app.color.kb_accent'))
        .transition(popTransition())
      } else {
        Text(`${step + 1}`)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_secondary'))
          .textAlign(TextAlign.Center)
          .width(26)
          .height(26)
          .borderRadius(13)
          .border({ width: 1.2, color: $r('app.color.app_separator') })
      }
    }
    .width(26)
    .height(26)
  }

  @Builder
  stepRow(step: SetupStep) {
    Row({ space: 14 }) {
      this.stepIndicator(step)
      Column({ space: 3 }) {
        Text(this.stepTitle(step))
          .fontSize(16)
          .fontColor($r('app.color.app_text'))
        if (!this.stepDone(step)) {
          Text(this.stepDetail(step))
            .fontSize(13)
            .fontColor($r('app.color.app_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (this.stepActive(step)) {
        Text(this.stepTrailing(step))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.kb_accent'))
          .textAlign(TextAlign.Center)
          .trailingSlot()
          .backgroundColor($r('app.color.app_accent_soft'))
          .stateStyles({ normal: this.pillNormal, pressed: this.pillPressed })
          .onClick(() => this.runStep(step))
      } else {
        Text(this.stepTrailing(step))
          .fontSize(14)
          .fontColor($r('app.color.app_text_secondary'))
          .textAlign(TextAlign.Center)
          .trailingSlot()
      }
    }
    .width('100%')
    .height(STEP_ROW_HEIGHT_VP)
    .padding({ left: 18, right: STEP_ROW_RIGHT_VP })
  }

  @Builder
  setupSection() {
    Column() {
      Row() {
        this.sectionTitle('设置')
        Blank()
        if (this.allReady()) {
          Text('已就绪')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.kb_accent'))
            .margin({ bottom: 10, right: SECTION_STATUS_RIGHT_VP })
            .transition(popTransition())
        }
      }
      .width('100%')
      Column() {
        ForEach(SETUP_STEPS, (step: SetupStep, index: number) => {
          if (index > 0) {
            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.app_separator'))
              .margin({ left: 58 })
          }
          this.stepRow(step)
        }, (step: SetupStep) => `step_${step}`)
      }
      .width('100%')
      .borderRadius(CARD_RADIUS_VP)
      .backgroundColor($r('app.color.app_card'))
    }
    .width('100%')
  }

  // ---------- 手势 ----------

  @Builder
  miniKey(label: string, hint: string, width: number) {
    Column() {
      if (hint.length > 0) {
        Text(hint)
          .fontSize(8)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.kb_accent'))
      }
      Text(label)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.key_text'))
    }
    .justifyContent(FlexAlign.Center)
    .width(width)
    .height(30)
    .borderRadius(6)
    .backgroundColor($r('app.color.key_background'))
    .shadow({ radius: 1, color: $r('app.color.key_shadow'), offsetY: 1 })
  }

  @Builder
  arrow(text: string) {
    Text(text)
      .fontSize(12)
      .fontWeight(FontWeight.Bold)
      .fontColor($r('app.color.kb_accent'))
  }

  // 每个手势配一个缩小的键盘示意，强调色标出手指的动作
  @Builder
  gestureVisual(visual: GestureVisual) {
    Stack() {
      if (visual === GestureVisual.FLICK) {
        Row({ space: 3 }) {
          this.miniKey('Q', '1', 24)
          this.arrow('↑')
        }
      } else if (visual === GestureVisual.SPACE) {
        Column({ space: 2 }) {
          this.arrow('←  →')
          Column()
            .width(40)
            .height(14)
            .borderRadius(4)
            .backgroundColor($r('app.color.key_background'))
            .shadow({ radius: 1, color: $r('app.color.key_shadow'), offsetY: 1 })
        }
      } else if (visual === GestureVisual.CLEAR) {
        Row({ space: 3 }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.delete_left'))
              .fontSize(13)
              .fontColor([$r('app.color.key_text')])
          }
          .width(26)
          .height(30)
          .borderRadius(6)
          .backgroundColor($r('app.color.key_function_background'))
          .shadow({ radius: 1, color: $r('app.color.key_shadow'), offsetY: 1 })
          this.arrow('↑')
        }
      } else if (visual === GestureVisual.MARK) {
        Image($r('app.media.aile_mark'))
          .width(24)
          .height(24)
          .draggable(false)
      } else if (visual === GestureVisual.CLIP) {
        Image($r('app.media.ic_clipboard'))
          .width(22)
          .height(22)
          .draggable(false)
      } else {
        Text('你好')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.kb_accent'))
      }
    }
    .width(60)
    .height(44)
    .borderRadius(12)
    .backgroundColor($r('app.color.app_pad'))
  }

  @Builder
  gestureItem(item: Gesture) {
    Row({ space: 14 }) {
      this.gestureVisual(item.visual)
      Column({ space: 3 }) {
        Text(item.title)
          .fontSize(15)
          .fontColor($r('app.color.app_text'))
          .maxLines(1)
        Text(item.detail)
          .fontSize(13)
          .fontColor($r('app.color.app_text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('50%')
    .padding({ left: 18, right: 12, top: 14, bottom: 14 })
  }

  @Builder
  gestureSection() {
    Column() {
      this.sectionTitle('手势')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(GESTURES, (item: Gesture) => {
          this.gestureItem(item)
        }, (item: Gesture) => item.title)
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .borderRadius(CARD_RADIUS_VP)
      .backgroundColor($r('app.color.app_card'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  // ---------- 试打 ----------

  @Styles
  fieldStyle() {
    .width('100%')
    .borderRadius(14)
    .backgroundColor($r('app.color.app_field'))
  }

  // 两栏时多行文本框填满卡片的剩余高度，单行输入框下方给出一行说明
  @Builder
  tryInput() {
    if (this.tryField === TryField.TEXT) {
      TextArea({ text: this.notes, placeholder: '试打一段文字' })
        .fieldStyle()
        .height(this.wide ? '100%' : NARROW_TEXT_HEIGHT_VP)
        .fontSize(16)
        .onChange((value: string) => {
          this.notes = value;
        })
    } else {
      Column({ space: 10 }) {
        this.singleLineInput()
        Text(TRY_CAPTIONS[this.tryField])
          .fontSize(13)
          .fontColor($r('app.color.app_text_tertiary'))
          .padding({ left: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
  }

  @Builder
  singleLineInput() {
    if (this.tryField === TryField.EMAIL) {
      TextInput({ placeholder: '输入邮箱' })
        .fieldStyle()
        .height(48)
        .type(InputType.Email)
    } else {
      TextInput({ placeholder: '输入数字' })
        .fieldStyle()
        .height(48)
        .type(InputType.Number)
    }
  }

  @Builder
  trySection() {
    Column() {
      this.sectionTitle('试一试')
      Column({ space: 16 }) {
        SegmentedTabs({
          items: TRY_TABS,
          selected: this.tryField,
          itemPadding: 14,
          trackColor: $r('app.color.app_segment_track'),
          select: (index: number) => {
            this.tryField = index;
          }
        })
        Column() {
          this.tryInput()
        }
        .width('100%')
        .layoutWeight(this.wide ? 1 : 0)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .layoutWeight(this.wide ? 1 : 0)
      .padding(18)
      .borderRadius(CARD_RADIUS_VP)
      .backgroundColor($r('app.color.app_card'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .height(this.wide && this.leftHeight > 0 ? this.leftHeight : 'auto')
  }

  // ---------- 页脚 ----------

  @Builder
  footer() {
    Text(this.version.length > 0 ? `Aile ${this.version} · 表情图案来自 Noto Emoji（Apache 2.0）` :
      '表情图案来自 Noto Emoji（Apache 2.0）')
      .fontSize(12)
      .fontColor($r('app.color.app_text_tertiary'))
      .padding({ left: 6 })
  }

  build() {
    Scroll() {
      Column({ space: 28 }) {
        this.header()
        // 默认断点下宽度不小于 840vp 为 lg，横屏平板分两栏，竖屏上下排列
        GridRow({
          columns: { xs: 4, sm: 4, md: 8, lg: 12 },
          gutter: { x: 24, y: 24 }
        }) {
          GridCol({ span: { xs: 4, sm: 4, md: 8, lg: 7 } }) {
            Column({ space: 24 }) {
              this.setupSection()
              this.gestureSection()
            }
            .onAreaChange((oldValue: Area, newValue: Area) => {
              this.leftHeight = Number(newValue.height);
            })
          }
          GridCol({ span: { xs: 4, sm: 4, md: 8, lg: 5 } }) {
            this.trySection()
          }
        }
        this.footer()
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .constraintSize({ maxWidth: 1120 })
      .padding({
        left: 40,
        right: 40,
        top: this.getUIContext().px2vp(this.insets.topPx) + PAGE_TOP_VP,
        bottom: this.getUIContext().px2vp(this.insets.bottomPx) + PAGE_BOTTOM_VP
      })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .backgroundColor($r('app.color.app_background'))
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.wide = Number(newValue.width) >= WIDE_WIDTH_VP;
    })
  }
}
