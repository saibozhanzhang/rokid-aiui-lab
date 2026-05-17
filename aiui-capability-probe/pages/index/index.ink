<script type="application/json" def>
{
  "navigationBarTitleText": "眼镜能力探测",
  "description": "打开即自动验证 Rokid Glasses AIUI 原生能力：相机、网络、TTS、宿主消息和退出。",
  "schema": {
    "data": {
      "type": "object",
      "properties": {
        "note": {
          "type": "string",
          "description": "可选测试备注。"
        }
      }
    }
  }
}
</script>

<script setup>
import wx from 'wx';

function safeString(value) {
  if (value === undefined) return 'undefined';
  if (value === null) return 'null';
  if (typeof value === 'string') return value;
  try {
    return JSON.stringify(value);
  } catch (err) {
    return String(value);
  }
}

function getErrorText(err) {
  if (!err) return 'unknown error';
  if (err.message) return err.message;
  return safeString(err);
}

function withTimeout(promise, ms, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(label + ' timeout after ' + ms + 'ms'));
    }, ms);
    promise
      .then((value) => {
        clearTimeout(timer);
        resolve(value);
      })
      .catch((err) => {
        clearTimeout(timer);
        reject(err);
      });
  });
}

function isBackKey(key) {
  const code = String(key || '');
  return code === 'Backspace' || code === 'BrowserBack' || code === 'GoBack' ||
    code === 'Escape' || code === '8' || code.toLowerCase() === 'back';
}

function isEnterKey(key) {
  const code = String(key || '');
  return code === 'Enter' || code === '13' || code.toLowerCase() === 'ok' ||
    code.toLowerCase() === 'center';
}

export default {
  data: {
    bootText: '等待自检',
    summaryText: '打开后会自动自检，无需点击。',
    lastEventText: '暂无宿主消息',
    cameraStatus: '未测',
    cameraDetail: '点击相机测试',
    networkStatus: '未测',
    networkDetail: '点击网络测试',
    ttsStatus: '未测',
    ttsDetail: '点击播报测试',
    messageStatus: '监听中',
    messageDetail: '支持 onMessage(event) 时会显示收到的 payload',
    exitStatus: '待测',
    exitDetail: '自动退出倒计时结束后会调用 exitMiniProgram',
    autoExitText: '60s 后自动退出',
    logLines: [
      '初始化完成后会自动标记运行时基础信息。'
    ],
    busy: false,
    autoRunStarted: false,
    autoExitSeconds: 60
  },

  onLoad(query) {
    const note = query && query.note ? String(query.note) : '';
    this.addLog('onLoad: ' + (note || '无启动参数'));
    this.setData({
      bootText: '已启动',
      summaryText: '自动自检即将开始。'
    });
    this.inspectRuntime();
    this.scheduleAutoRun();
    this.startAutoExitCountdown();
  },

  onShow() {
    this.addLog('onShow');
    this.scheduleAutoRun();
  },

  onHide() {
    this.addLog('onHide');
  },

  onUnload() {
    this.clearTimers();
    this.addLog('onUnload');
  },

  onMessage(event) {
    const payload = event && event.data !== undefined ? event.data : event;
    const text = safeString(payload);
    this.setData({
      lastEventText: text,
      messageStatus: '已收到',
      messageDetail: text.slice(0, 180)
    });
    this.addLog('onMessage: ' + text.slice(0, 80));
  },

  onKeyDown(event) {
    const key = event && (event.key || event.code || event.keyCode);
    this.addLog('onKeyDown: ' + safeString(key));
    if (isBackKey(key)) {
      this.exitAgent();
      return;
    }
    if (isEnterKey(key)) {
      this.runAll();
    }
  },

  onVoiceWakeup(event) {
    this.addLog('onVoiceWakeup: ' + safeString(event).slice(0, 80));
    this.runAll();
  },

  onRootTap() {
    this.addLog('root tap');
    this.runAll();
  },

  inspectRuntime() {
    const hasWx = typeof wx !== 'undefined';
    const hasMedia = !!(hasWx && wx.media);
    const hasCameraFactory = !!(hasWx && wx.media && wx.media.createCameraContext);
    const hasRequest = !!(hasWx && wx.request);
    const hasTts = !!(hasWx && wx.speech && wx.speech.playTTS);
    const hasSpeechSynthesis = typeof speechSynthesis !== 'undefined';
    this.addLog('runtime wx=' + hasWx + ', media=' + hasMedia + ', camera=' + hasCameraFactory);
    this.addLog('runtime request=' + hasRequest + ', wxTTS=' + hasTts + ', speechSynthesis=' + hasSpeechSynthesis);
  },

  scheduleAutoRun() {
    if (this.data.autoRunStarted || this.autoRunTimer) return;
    this.autoRunTimer = setTimeout(() => {
      this.autoRunTimer = null;
      this.setData({ autoRunStarted: true });
      this.runAll();
    }, 700);
  },

  startAutoExitCountdown() {
    if (this.autoExitTimer) return;
    this.autoExitTimer = setInterval(() => {
      const left = Math.max(0, (this.data.autoExitSeconds || 0) - 1);
      this.setData({
        autoExitSeconds: left,
        autoExitText: left > 0 ? left + 's 后自动退出' : '正在自动退出'
      });
      if (left <= 0) {
        this.exitAgent();
      }
    }, 1000);
  },

  clearTimers() {
    if (this.autoRunTimer) {
      clearTimeout(this.autoRunTimer);
      this.autoRunTimer = null;
    }
    if (this.autoExitTimer) {
      clearInterval(this.autoExitTimer);
      this.autoExitTimer = null;
    }
  },

  addLog(line) {
    const time = new Date();
    const hh = String(time.getHours()).padStart(2, '0');
    const mm = String(time.getMinutes()).padStart(2, '0');
    const ss = String(time.getSeconds()).padStart(2, '0');
    const next = [hh + ':' + mm + ':' + ss + ' ' + line].concat(this.data.logLines || []);
    this.setData({
      logLines: next.slice(0, 8)
    });
  },

  async runAll() {
    if (this.data.busy) return;
    this.setData({
      busy: true,
      summaryText: '正在自动自检...'
    });
    await this.testCamera();
    await this.testNetwork();
    await this.testTts();
    this.speakSummary();
    this.setData({
      busy: false,
      summaryText: '自检完成。' + this.data.autoExitText
    });
  },

  async testCamera() {
    this.setData({
      cameraStatus: '测试中',
      cameraDetail: '检查 wx.media.createCameraContext...'
    });
    this.addLog('camera: start');

    try {
      if (!wx || !wx.media || !wx.media.createCameraContext) {
        throw new Error('wx.media.createCameraContext 不存在');
      }

      const camera = wx.media.createCameraContext();
      if (!camera) {
        throw new Error('createCameraContext 返回空值');
      }
      if (!camera.takePhoto) {
        throw new Error('camera.takePhoto 不存在');
      }

      const photo = await withTimeout(
        Promise.resolve(camera.takePhoto({ quality: 'low' })),
        8000,
        'takePhoto'
      );

      const keys = photo && typeof photo === 'object' ? Object.keys(photo).join(', ') : typeof photo;
      let sizeText = '';
      if (photo && photo.data && photo.data.byteLength !== undefined) {
        sizeText = 'data.byteLength=' + photo.data.byteLength;
      } else if (photo && photo.tempFilePath) {
        sizeText = 'tempFilePath=' + photo.tempFilePath;
      } else {
        sizeText = safeString(photo).slice(0, 120);
      }

      this.setData({
        cameraStatus: '成功',
        cameraDetail: '返回字段: ' + keys + '；' + sizeText
      });
      this.addLog('camera: success ' + keys);
    } catch (err) {
      this.setData({
        cameraStatus: '失败',
        cameraDetail: getErrorText(err)
      });
      this.addLog('camera: fail ' + getErrorText(err));
    }
  },

  async testNetwork() {
    this.setData({
      networkStatus: '测试中',
      networkDetail: '请求 https://www.rokid.com ...'
    });
    this.addLog('network: start');

    try {
      if (!wx || !wx.request) {
        throw new Error('wx.request 不存在');
      }
      await withTimeout(new Promise((resolve, reject) => {
        wx.request({
          url: 'https://www.rokid.com',
          method: 'GET',
          success: (res) => resolve(res),
          fail: (err) => reject(err)
        });
      }), 8000, 'wx.request');

      this.setData({
        networkStatus: '成功',
        networkDetail: 'wx.request 可用'
      });
      this.addLog('network: success');
    } catch (err) {
      this.setData({
        networkStatus: '失败',
        networkDetail: getErrorText(err)
      });
      this.addLog('network: fail ' + getErrorText(err));
    }
  },

  async testTts() {
    this.setData({
      ttsStatus: '测试中',
      ttsDetail: '尝试 wx.speech.playTTS / speechSynthesis'
    });
    this.addLog('tts: start');

    try {
      if (wx && wx.speech && wx.speech.playTTS) {
        wx.speech.playTTS({
          text: '眼镜能力探测，语音播报测试',
          success: () => this.addLog('tts: wx success callback'),
          fail: (e) => this.addLog('tts: wx fail callback ' + getErrorText(e))
        });
        this.setData({
          ttsStatus: '已调用',
          ttsDetail: '已调用 wx.speech.playTTS'
        });
        this.addLog('tts: wx.speech.playTTS called');
        return;
      }

      if (typeof speechSynthesis !== 'undefined' && typeof SpeechSynthesisUtterance !== 'undefined') {
        const utterance = new SpeechSynthesisUtterance('眼镜能力探测，语音播报测试');
        utterance.lang = 'zh-CN';
        speechSynthesis.speak(utterance);
        this.setData({
          ttsStatus: '已调用',
          ttsDetail: '已调用 speechSynthesis'
        });
        this.addLog('tts: speechSynthesis called');
        return;
      }

      throw new Error('未发现 TTS API');
    } catch (err) {
      this.setData({
        ttsStatus: '失败',
        ttsDetail: getErrorText(err)
      });
      this.addLog('tts: fail ' + getErrorText(err));
    }
  },

  speakSummary() {
    const text = '能力探测完成。相机' + this.data.cameraStatus +
      '，网络' + this.data.networkStatus +
      '，语音' + this.data.ttsStatus +
      '。稍后自动退出。';
    try {
      if (wx && wx.speech && wx.speech.playTTS) {
        wx.speech.playTTS({ text });
        return;
      }
    } catch (err) {}
    try {
      if (typeof speechSynthesis !== 'undefined' && typeof SpeechSynthesisUtterance !== 'undefined') {
        const utterance = new SpeechSynthesisUtterance(text);
        utterance.lang = 'zh-CN';
        speechSynthesis.speak(utterance);
      }
    } catch (err2) {}
  },

  exitAgent() {
    this.clearTimers();
    this.setData({
      exitStatus: '退出中',
      exitDetail: '正在调用 exitMiniProgram / navigateBack'
    });
    this.addLog('exit: requested');

    try {
      if (wx && typeof wx.exitMiniProgram === 'function') {
        wx.exitMiniProgram({
          success: () => this.addLog('exitMiniProgram success'),
          fail: (e) => this.addLog('exitMiniProgram fail ' + getErrorText(e))
        });
      }
    } catch (err) {
      this.addLog('exitMiniProgram threw: ' + getErrorText(err));
    }

    setTimeout(() => {
      try {
        if (wx && wx.navigateBack) {
          wx.navigateBack({ delta: 1 });
          return;
        }
      } catch (err2) {
        this.addLog('navigateBack fail: ' + getErrorText(err2));
      }

      try {
        if (typeof this.finish === 'function') {
          this.finish();
          return;
        }
      } catch (err3) {
        this.addLog('finish fail: ' + getErrorText(err3));
      }

      this.setData({
        exitStatus: '失败',
        exitDetail: '没有可用退出 API'
      });
    }, 500);
  }
};
</script>

<page>
  <view class="page" bindtap="onRootTap">
    <view class="hero">
      <text class="kicker">AIUI 原生能力</text>
      <text class="title">眼镜能力探测</text>
      <text class="subtitle">{{summaryText}}</text>
      <text class="auto-exit">{{autoExitText}}</text>
    </view>

    <view class="status-grid">
      <view class="status-card">
        <text class="label">启动</text>
        <text class="value">{{bootText}}</text>
      </view>
      <view class="status-card">
        <text class="label">宿主消息</text>
        <text class="value">{{messageStatus}}</text>
      </view>
    </view>

    <view class="panel">
      <view class="row">
        <view class="copy">
          <text class="row-title">相机</text>
          <text class="row-sub">{{cameraDetail}}</text>
        </view>
        <text class="pill">{{cameraStatus}}</text>
      </view>
      <button class="button" bindtap="testCamera">测试相机</button>
    </view>

    <view class="panel">
      <view class="row">
        <view class="copy">
          <text class="row-title">网络</text>
          <text class="row-sub">{{networkDetail}}</text>
        </view>
        <text class="pill">{{networkStatus}}</text>
      </view>
      <button class="button" bindtap="testNetwork">测试网络</button>
    </view>

    <view class="panel">
      <view class="row">
        <view class="copy">
          <text class="row-title">语音播报</text>
          <text class="row-sub">{{ttsDetail}}</text>
        </view>
        <text class="pill">{{ttsStatus}}</text>
      </view>
      <button class="button" bindtap="testTts">测试播报</button>
    </view>

    <view class="panel">
      <view class="row">
        <view class="copy">
          <text class="row-title">退出</text>
          <text class="row-sub">{{exitDetail}}</text>
        </view>
        <text class="pill">{{exitStatus}}</text>
      </view>
      <button class="button danger" bindtap="exitAgent">退出 Agent</button>
    </view>

    <view class="action-row">
      <button class="primary" bindtap="runAll">{{busy ? '自检中' : '重新自检'}}</button>
    </view>

    <view class="log-panel">
      <text class="log-title">最近日志</text>
      <text class="event-text">消息: {{lastEventText}}</text>
      <view class="log-line" ink:for="{{logLines}}" ink:key="index">
        <text>{{item}}</text>
      </view>
    </view>
  </view>
</page>

<style>
.page {
  width: 100%;
  min-height: 100vh;
  box-sizing: border-box;
  padding: 14px;
  background-color: #020402;
  color: #d8ffe2;
  flex-direction: column;
}

.hero {
  flex-direction: column;
  margin-bottom: 10px;
}

.kicker {
  color: #6df28a;
  font-size: 12px;
  line-height: 16px;
  font-weight: 700;
}

.title {
  color: #f2fff5;
  font-size: 30px;
  line-height: 34px;
  font-weight: 800;
}

.subtitle {
  color: #8cad94;
  font-size: 14px;
  line-height: 19px;
  margin-top: 4px;
}

.auto-exit {
  color: #64f27f;
  font-size: 13px;
  line-height: 18px;
  margin-top: 4px;
}

.status-grid {
  flex-direction: row;
  gap: 8px;
  margin-bottom: 8px;
}

.status-card {
  flex: 1;
  border: 1px solid #174421;
  border-radius: 8px;
  padding: 8px 10px;
  background-color: #071009;
  flex-direction: column;
}

.label {
  color: #6a8f72;
  font-size: 11px;
  line-height: 14px;
}

.value {
  color: #d8ffe2;
  font-size: 16px;
  line-height: 22px;
  font-weight: 700;
}

.panel {
  border: 1px solid #183d21;
  border-radius: 8px;
  padding: 10px;
  margin-bottom: 8px;
  background-color: #071009;
  flex-direction: column;
}

.row {
  flex-direction: row;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.copy {
  flex: 1;
  flex-direction: column;
}

.row-title {
  color: #f2fff5;
  font-size: 18px;
  line-height: 23px;
  font-weight: 700;
}

.row-sub {
  color: #90ad98;
  font-size: 12px;
  line-height: 17px;
  margin-top: 2px;
}

.pill {
  min-width: 58px;
  text-align: center;
  color: #72ff91;
  border: 1px solid #226c35;
  border-radius: 999px;
  padding: 4px 8px;
  font-size: 12px;
  line-height: 16px;
}

.button,
.primary {
  margin-top: 8px;
  height: 36px;
  border-radius: 8px;
  border: 1px solid #2e8e44;
  color: #92ffa7;
  background-color: transparent;
  font-size: 15px;
  line-height: 36px;
  text-align: center;
}

.danger {
  color: #ff9c91;
  border-color: #763229;
}

.action-row {
  margin-bottom: 8px;
}

.primary {
  width: 100%;
  color: #041006;
  background-color: #64f27f;
  border-color: #64f27f;
  font-weight: 800;
}

.log-panel {
  border: 1px solid #183d21;
  border-radius: 8px;
  padding: 10px;
  background-color: #050b06;
  flex-direction: column;
}

.log-title {
  color: #f2fff5;
  font-size: 14px;
  line-height: 18px;
  font-weight: 700;
  margin-bottom: 4px;
}

.event-text,
.log-line {
  color: #7f9f86;
  font-size: 11px;
  line-height: 16px;
}
</style>
