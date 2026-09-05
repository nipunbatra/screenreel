// One active decoder at a time. No autoplay or background animation timers.
// Kept separate from DOM wiring so lifecycle behavior has regression tests.
export function managePlayback(videos, {visible = () => true, changed = () => {}} = {}) {
  const disposers = [];
  const pauseAll = () => videos.forEach(video => video.pause());
  for (const video of videos) {
    const onPlay = () => {
      if (!visible()) { video.pause(); return; }
      videos.forEach(other => { if (other !== video) other.pause(); });
      changed(video, true);
    };
    const onPause = () => changed(video, false);
    video.addEventListener('play', onPlay);
    video.addEventListener('pause', onPause);
    video.addEventListener('ended', onPause);
    disposers.push(() => {
      video.removeEventListener('play', onPlay);
      video.removeEventListener('pause', onPause);
      video.removeEventListener('ended', onPause);
    });
  }
  return {
    async toggle(video, {audible = false, restart = false} = {}) {
      if (!videos.includes(video)) return;
      if (!video.paused) { video.pause(); return; }
      if (!visible()) return;
      if (audible) video.muted = false;
      if (restart) video.currentTime = 0;
      await video.play();
      // A pending play promise may resolve after the page became hidden.
      if (!visible()) video.pause();
    },
    visibilityChanged() { if (!visible()) pauseAll(); },
    outOfView(video) { if (videos.includes(video)) video.pause(); },
    destroy() { pauseAll(); disposers.forEach(dispose => dispose()); }
  };
}

export function mountGallery(document, Observer = globalThis.IntersectionObserver) {
  const videos = [...document.querySelectorAll('[data-gallery-video]')];
  const status = document.querySelector('#gallery-status');
  const playback = managePlayback(videos, {
    visible: () => !document.hidden,
    changed(video, playing) {
      const button = document.querySelector(`[data-play="${video.id}"]`);
      if (button) {
        button.textContent = `${playing ? 'Pause' : 'Play'} ${video.dataset.label}`;
        button.setAttribute('aria-pressed', String(playing));
      }
    }
  });
  document.querySelectorAll('[data-play]').forEach(button => {
    button.addEventListener('click', async () => {
      try {
        status.textContent = '';
        await playback.toggle(document.getElementById(button.dataset.play), {
          audible: button.hasAttribute('data-audible'), restart: button.hasAttribute('data-restart')
        });
      } catch {
        status.textContent = 'The inline demo could not play. Open the MP4 link below it.';
      }
    });
  });
  document.addEventListener('visibilitychange', () => playback.visibilityChanged());
  const observer = Observer ? new Observer(entries => {
    entries.forEach(entry => { if (!entry.isIntersecting) playback.outOfView(entry.target); });
  }) : null;
  videos.forEach(video => observer?.observe(video));

  const dialog = document.querySelector('#screenshot-dialog');
  const dialogImage = dialog?.querySelector('img');
  document.querySelectorAll('[data-screenshot]').forEach(link => {
    link.addEventListener('click', event => {
      // Without dialog support, the normal link still opens the screenshot.
      if (!dialog?.showModal || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      playback.visibilityChanged();
      videos.forEach(video => playback.outOfView(video));
      dialogImage.src = link.href;
      dialogImage.alt = link.dataset.screenshot || link.querySelector('img')?.alt || 'Screen Reel screenshot';
      dialog.showModal();
    });
  });
  dialog?.querySelector('[data-close]')?.addEventListener('click', () => dialog.close());
  dialog?.addEventListener('click', event => { if (event.target === dialog) dialog.close(); });
  return playback;
}

if (typeof document !== 'undefined') mountGallery(document);
