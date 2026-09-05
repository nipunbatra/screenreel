import {test} from 'node:test';
import assert from 'node:assert/strict';
import {managePlayback} from '../../website/gallery.mjs';

class Video extends EventTarget {
  paused = true;
  playCalls = 0;
  async play() { this.playCalls++; this.paused = false; this.dispatchEvent(new Event('play')); }
  pause() { if (!this.paused) { this.paused = true; this.dispatchEvent(new Event('pause')); } }
}

test('mounting leaves every demo paused without loading or playing', () => {
  const videos = [new Video(), new Video()];
  managePlayback(videos);
  assert.ok(videos.every(v => v.paused && v.playCalls === 0));
});
test('only one video plays, including starts through native video controls', async () => {
  const a = new Video(), b = new Video();
  const playback = managePlayback([a, b]);
  await playback.toggle(a);
  await b.play();
  assert.equal(a.paused, true);
  assert.equal(b.paused, false);
});
test('the same button toggles playback and reports both states', async () => {
  const video = new Video(), states = [];
  const playback = managePlayback([video], {changed: (_, playing) => states.push(playing)});
  await playback.toggle(video);
  await playback.toggle(video);
  assert.deepEqual(states, [true, false]);
});
test('scrolling a demo offscreen pauses it, with no automatic resume', async () => {
  const video = new Video();
  const playback = managePlayback([video]);
  await playback.toggle(video);
  playback.outOfView(video);
  assert.equal(video.paused, true);
  assert.equal(video.playCalls, 1);
});
test('a hidden page stops playback and rejects new play requests', async () => {
  let visible = true;
  const video = new Video();
  const playback = managePlayback([video], {visible: () => visible});
  await playback.toggle(video);
  visible = false;
  playback.visibilityChanged();
  await playback.toggle(video);
  assert.equal(video.paused, true);
  assert.equal(video.playCalls, 1);
  visible = true;
  playback.visibilityChanged();
  assert.equal(video.paused, true);
});
test('a native control play event cannot start a hidden-page decoder', async () => {
  const video = new Video();
  managePlayback([video], {visible: () => false});
  await video.play();
  assert.equal(video.paused, true);
});
test('a delayed play promise is paused when visibility changes', async () => {
  let visible = true, resolve;
  const video = new Video();
  video.play = () => new Promise(done => { resolve = () => { video.paused = false; done(); }; });
  const playback = managePlayback([video], {visible: () => visible});
  const pending = playback.toggle(video);
  visible = false;
  resolve();
  await pending;
  assert.equal(video.paused, true);
});
test('play failures propagate to the UI fallback without reporting playing', async () => {
  const video = new Video(), states = [];
  video.play = async () => { throw new Error('unsupported media'); };
  const playback = managePlayback([video], {changed: (_, playing) => states.push(playing)});
  await assert.rejects(playback.toggle(video), /unsupported media/);
  assert.deepEqual(states, []);
});
test('unknown elements cannot be played through the controller', async () => {
  const video = new Video();
  await managePlayback([]).toggle(video);
  assert.equal(video.playCalls, 0);
});
test('cleanup stops decoders and removes playback listeners', async () => {
  const a = new Video(), b = new Video();
  const playback = managePlayback([a, b]);
  await playback.toggle(a);
  playback.destroy();
  assert.equal(a.paused, true);
  await a.play();
  await b.play();
  assert.equal(a.paused, false, 'old controller must no longer react to events');
});
