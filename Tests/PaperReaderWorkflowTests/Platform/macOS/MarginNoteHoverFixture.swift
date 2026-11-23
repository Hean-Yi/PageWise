#if os(macOS)
    enum MarginNoteHoverFixture {
        static let check = #"""
            const root = document.getElementById('reader');
            const sections = [...root.querySelectorAll('section[data-key]')];
            const wait = (ms = 70) => new Promise(done => setTimeout(done, ms));
            const settle = async () => { await wait(500); await wait(); };
            const move = ({x, y}) => {
              const target = document.elementFromPoint(x, y) || document;
              target.dispatchEvent(new PointerEvent('pointermove', {bubbles:true, clientX:x, clientY:y, pointerType:'mouse'}));
            };
            const midway = (a, b, t) => ({x:a.x + (b.x - a.x) * t, y:a.y + (b.y - a.y) * t});
            const failures = [];
            const check = (ok, message) => { if (!ok) failures.push(message); };

            root.style.maxWidth = '660px';
            paperNotes.sidebar(false);
            await document.fonts.ready;
            await wait();
            if (sections.length !== 12) return ['missing paper sections: ' + sections.length];

            const source = sections[0].querySelector('p').firstChild;
            const range = document.createRange();
            range.setStart(source, 0);
            // Stop in the middle of a printed line, leaving ordinary text between the anchor and the margin.
            let lines = [];
            for (let end = 1; end <= source.length; end++) {
              range.setEnd(source, end);
              lines = [...range.getClientRects()].filter(r => r.width > 0);
              if (lines.length === 2 && lines[1].width >= 120) break;
            }
            if (lines.length !== 2 || lines[0].right - lines[1].right < 90) return ['expected a partial second line'];
            const last = lines[1];
            const point = {x:last.right - 6, y:(last.top + last.bottom) / 2};
            const translated = sections[0].querySelector('.translation').firstChild;
            const secondRange = document.createRange();
            secondRange.selectNodeContents(translated);
            const secondBox = secondRange.getClientRects()[0];
            const second = {x:secondBox.left + 8, y:(secondBox.top + secondBox.bottom) / 2};
            const note = (id, key, target, text, markdown) => ({id, anchors:[{key, target, text, start:0, end:text.length}], markdown});
            const notes = [
              note('wrapped', sections[0].dataset.key, 'source', range.toString(), 'Evidence at matched capacity. '.repeat(28)),
              note('next', sections[0].dataset.key, 'translation', translated.data, 'Another note.'),
              ...sections.slice(1).map(section => note(section.id, section.dataset.key, 'source',
                section.querySelector('p').textContent.slice(0, 14), 'A note from another page.'))
            ];
            paperNotes.sync(notes);
            await wait(150);
            const card = id => document.querySelector('.reader-note-card[data-note-id="' + id + '"]');
            const active = () => document.querySelector('.reader-note-card.active')?.dataset.noteId;
            const cross = (start, end, direction) => {
              // A WKWebView outside a window throttles timers to one second. Deliver the
              // render callbacks for each mouse sample; stopping on blank text below uses real timers.
              const original = window.requestAnimationFrame, frames = [];
              window.requestAnimationFrame = callback => frames.push(callback);
              try {
                for (let i = 1; i <= 10; i++) {
                  move(midway(start, end, i / 10));
                  for (const callback of frames.splice(0)) callback(performance.now());
                  if (active() !== 'wrapped') { failures.push('lost note ' + direction + ' at step ' + i); break; }
                }
              } finally {
                window.requestAnimationFrame = original;
              }
            };
            const wrapped = card('wrapped'), neighbor = card('next');
            if (wrapped.hidden || wrapped.dataset.placement !== 'right' || neighbor.hidden) return ['missing resting margin cards'];
            const neighborTop = neighbor.getBoundingClientRect().top;
            const away = {x:innerWidth - 2, y:2};
            const blank = {x:last.right + 45, y:point.y};
            move(blank); await wait();
            check(!active(), 'unmarked text activated a note');

            const remote = new Set(sections.slice(3));
            const measured = new Set();
            const getRects = Range.prototype.getClientRects;
            Range.prototype.getClientRects = function() {
              const section = this.startContainer.parentElement?.closest('section');
              if (remote.has(section)) measured.add(section.id);
              return getRects.call(this);
            };
            try {
              move(point); await wait();
              check(active() === 'wrapped', 'wrapped text did not activate its note');
              const box = wrapped.getBoundingClientRect();
              const inside = {x:box.left + 15, y:Math.max(box.top + 15, Math.min(box.bottom - 15, point.y))};
              check(Math.abs(neighborTop - neighbor.getBoundingClientRect().top) < 1, 'neighbor moved when preview expanded');
              cross(point, inside, 'on the way to the card');
              await settle();
              check(active() === 'wrapped' && wrapped.contains(document.elementFromPoint(inside.x, inside.y)),
                'card did not keep the pointer');
              cross(inside, point, 'returning to the highlight');
              move(away); await settle();
              check(!active(), 'moving outside the note did not dismiss it');
              move(point); await wait();
              move(blank); await settle();
              check(!active(), 'hover remained active on ordinary text');

              move(point); await wait();
              move(second); await wait();
              check(active() === 'next', 'moving directly to the next highlight did not switch notes');
              move(away); await settle();
              check(!active(), 'second note did not dismiss');
              check(measured.size === 0, 'hover measured ' + measured.size + ' unrelated pages');
            } finally {
              Range.prototype.getClientRects = getRects;
            }
            // The pointer can enter a card while only its top or bottom strip is visible.
            const clipped = card(sections[5].id);
            const documentTop = clipped.getBoundingClientRect().top + scrollY;
            const height = clipped.getBoundingClientRect().height;
            for (const edge of ['top', 'bottom']) {
              const clipAtTop = edge === 'top';
              window.scrollTo({top:clipAtTop ? documentTop + height - 26 : documentTop - innerHeight + 26,
                behavior:'instant'});
              await wait();
              const rest = clipped.getBoundingClientRect();
              if (clipAtTop ? !(rest.top < 0 && rest.bottom > 12) : !(rest.top < innerHeight - 12 && rest.bottom > innerHeight)) {
                failures.push('fixture did not clip the card at viewport ' + edge);
                continue;
              }
              const pointer = {x:(rest.left + rest.right) / 2, y:clipAtTop ? 6 : innerHeight - 6};
              if (!clipped.contains(document.elementFromPoint(pointer.x, pointer.y))) {
                failures.push('resting card missed the pointer before hover at viewport ' + edge);
                continue;
              }
              move(pointer); await wait();
              // Native hit testing repeats when expansion changes what is under the cursor.
              for (let i = 0; i < 3; i++) {
                move(pointer); await wait();
                if (!clipped.classList.contains('active') || !clipped.contains(document.elementFromPoint(pointer.x, pointer.y))) {
                  failures.push('stationary pointer lost the card at viewport ' + edge);
                  break;
                }
              }
              move(away); await settle();
              check(!active(), 'clipped preview did not dismiss at viewport ' + edge);
            }
            return failures;
            """#
    }
#endif
