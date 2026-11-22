#if os(macOS)
    import AppKit
    import Testing
    import WebKit
    @testable import PaperReaderUI

    @Test @MainActor func imagePreviewPreservesGeometryAndQuotesOriginalImage() async throws {
        let web = imagePreviewFixture()
        try await previewWait(web, "return document.querySelector('#figure')?.naturalWidth===200")
        #expect(
            try await previewJS(
                web,
                "document.querySelector('#before').focus();window.original=document.querySelector('#figure');window.box=original.getBoundingClientRect();window.y=scrollY;original.click();return true"
            ) as? Bool == true)
        try await previewWait(
            web, "return !!document.querySelector('#reader-image-preview[data-state=open]')", settle: false)
        let geometryPreserved =
            try await previewJS(
                web,
                #"""
                const image=document.querySelector('.preview-image');
                const current=original.getBoundingClientRect();
                window.previewGeometry={pixels:image.width,width:parseFloat(image.style.width),boxWidth:box.width,top:current.top,oldTop:box.top,height:current.height,oldHeight:box.height,scroll:scrollY,oldScroll:y,visibility:getComputedStyle(original).visibility};
                return image.width>0 && image.imageSource===original && parseFloat(image.style.width)>box.width
                  && Math.abs(parseFloat(image.style.width)/parseFloat(image.style.height)-2)<.001
                  && original===document.querySelector('#figure') && current.top===box.top && current.height===box.height
                  && scrollY===y && getComputedStyle(original).visibility==='hidden';
                """#
            ) as? Bool
        let geometry = try await previewJS(web, "return window.previewGeometry")
        #expect(geometryPreserved == true, "\(String(describing: geometry))")
        // Close while the opening animation is still running, and preserve the original reference.
        _ = try await previewJS(web, "document.querySelector('.preview-tools button').click()")
        try await previewWait(web, "return !document.querySelector('#reader-image-preview')")
        #expect(
            try await previewJS(
                web,
                "return window.quoted===original && original.style.visibility==='' && scrollY===y && document.activeElement.id==='before'"
            ) as? Bool == true)
        _ = try await previewJS(web, "original.click();original.click()")
        try await previewWait(web, "return !!document.querySelector('#reader-image-preview[data-state=open]')")
        #expect(
            try await previewJS(web, "return document.querySelectorAll('#reader-image-preview').length") as? Int == 1)
        _ = try await previewJS(web, "document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))")
        try await previewWait(
            web, "return !document.querySelector('#reader-image-preview') && original.style.visibility==='' ")
    }

    @Test @MainActor func imagePreviewHandlesDragReducedMotionResizeAndBrokenImages() async throws {
        let web = imagePreviewFixture()
        try await previewWait(web, "return document.querySelector('#bitmap')?.naturalWidth>0")
        _ = try await previewJS(
            web,
            #"""
            window.original=document.querySelector('#figure');
            original.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,clientX:50,clientY:50}));
            original.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,buttons:1,clientX:80,clientY:50}));
            original.dispatchEvent(new MouseEvent('click',{bubbles:true,detail:1,clientX:80,clientY:50}));
            """#)
        #expect(try await previewJS(web, "return !document.querySelector('#reader-image-preview')") as? Bool == true)
        _ = try await previewJS(
            web,
            "window.matchMedia=()=>({matches:true});document.querySelector('#bitmap').click()")
        try await previewWait(web, "return !!document.querySelector('#reader-image-preview[data-state=open]')")
        #expect(
            try await previewJS(
                web,
                "return document.getAnimations().length===0 && getComputedStyle(document.querySelector('.preview-backdrop')).opacity==='1'"
            ) as? Bool == true)
        #expect(
            try await previewJS(
                web,
                #"""
                const overlay=document.querySelector('#reader-image-preview');
                const wheel=new WheelEvent('wheel',{bubbles:true,cancelable:true,deltaY:100});
                overlay.dispatchEvent(wheel);
                const down=new KeyboardEvent('keydown',{key:'PageDown',bubbles:true,cancelable:true});
                document.dispatchEvent(down);
                const buttons=overlay.querySelectorAll('button');buttons[1].focus();
                document.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));
                return wheel.defaultPrevented && down.defaultPrevented && document.activeElement===buttons[0];
                """#
            ) as? Bool == true)
        web.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        _ = try await previewJS(web, "window.dispatchEvent(new Event('resize'))")
        #expect(
            try await previewJS(
                web,
                "const r=document.querySelector('.preview-image').getBoundingClientRect();return r.left>=19 && r.right<=innerWidth-19 && r.bottom<=innerHeight && r.top>=70"
            ) as? Bool == true)
        _ = try await previewJS(web, "document.querySelector('.preview-backdrop').click()")
        try await previewWait(web, "return !document.querySelector('#reader-image-preview')")
        _ = try await previewJS(
            web,
            "const broken=document.createElement('img');document.querySelector('#reader').append(broken);broken.click()"
        )
        #expect(
            try await previewJS(
                web,
                "return !document.querySelector('#reader-image-preview')"
            ) as? Bool == true)
    }

    @Test @MainActor func imagePreviewStartsSynchronouslyAndClosesWithPausedAnimationClock() async throws {
        let web = imagePreviewFixture()
        try await previewWait(web, "return document.querySelector('#figure')?.naturalWidth===200")
        #expect(
            try await previewJS(
                web,
                #"""
                HTMLImageElement.prototype.decode=()=>new Promise(()=>{});
                document.querySelector('#figure').click();
                return !!document.querySelector('#reader-image-preview[data-state=open]');
                """#
            ) as? Bool == true)
        #expect(
            try await previewJS(
                web,
                #"""
                window.paperImagePreview.close();
                for(const animation of document.getAnimations())animation.pause();
                await new Promise(resolve=>setTimeout(resolve,400));
                return !document.querySelector('#reader-image-preview')
                 
                  && document.querySelector('#figure').style.visibility==='';
                """#
            ) as? Bool == true)
    }

    @Test @MainActor func pdfImagePreviewZoomsAndPansWithoutLeavingReadingPosition() async throws {
        let web = imagePreviewFixture()
        try await previewWait(web, "return document.querySelector('#figure')?.naturalWidth === 200")
        _ = try await previewJS(
            web,
            """
            window.matchMedia=()=>({matches:true});
            window.openPDF=()=>{
              const image=document.querySelector('#figure'), opener=document.querySelector('#before');
              window.paperImagePreview.open(image,{title:'表 8',details:true,opener,
                actionLabel:'查看原页',onAction:source=>{window.openedSource=source;window.actions=(window.actions||0)+1;}});
            };
            window.y=scrollY;openPDF();
            """)
        let opened =
            try await previewJS(
                web,
                """
                const dialog=document.querySelector('#reader-image-preview'), buttons=[...dialog.querySelectorAll('button')];
                buttons[0].click();
                const pane=dialog.querySelector('.preview-viewport');
                const wheel=new WheelEvent('wheel',{bubbles:true,cancelable:true,deltaX:42});
                pane.dispatchEvent(wheel);
                const touch=new Event('touchmove',{bubbles:true,cancelable:true});
                pane.dispatchEvent(touch);
                for(const key of ['ArrowRight','PageDown']){
                  document.dispatchEvent(new KeyboardEvent('keydown',{key,bubbles:true,cancelable:true}));
                }
                return dialog.getAttribute('aria-label')==='表 8'
                  && buttons.map(b=>b.textContent).join('|')==='适合窗口|查看原页|关闭'
                  && buttons[0].getAttribute('aria-pressed')==='true' && !wheel.defaultPrevented && !touch.defaultPrevented
                  && pane.scrollWidth>pane.clientWidth && pane.scrollHeight>pane.clientHeight
                  && pane.scrollLeft>0 && pane.scrollTop>0 && scrollY===window.y;
                """) as? Bool
        #expect(opened == true)
        web.frame = CGRect(x: 0, y: 0, width: 420, height: 620)
        #expect(
            try await previewJS(
                web,
                """
                window.dispatchEvent(new Event('resize'));
                const pane=document.querySelector('.preview-viewport');
                return !pane.hidden && pane.scrollWidth>pane.clientWidth && scrollY===window.y;
                """) as? Bool == true)
        let reset =
            try await previewJS(
                web,
                """
                const dialog=document.querySelector('#reader-image-preview'), buttons=dialog.querySelectorAll('button');
                buttons[0].click();buttons[0].focus();
                document.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',shiftKey:true,bubbles:true,cancelable:true}));
                return dialog.querySelector('.preview-viewport').hidden && !dialog.hasAttribute('data-zoomed')
                  && dialog.querySelector('.preview-image').getBoundingClientRect().width < innerWidth
                  && document.activeElement===buttons[buttons.length-1];
                """) as? Bool
        #expect(reset == true)
        _ = try await previewJS(web, "document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true}))")
        try await previewWait(
            web, "return !document.querySelector('#reader-image-preview') && document.activeElement.id==='before'")
        #expect(try await previewJS(web, "return !window.openedSource && scrollY===window.y") as? Bool == true)
        _ = try await previewJS(web, "openPDF();document.querySelector('.preview-tools button:nth-child(2)').click()")
        try await previewWait(
            web,
            "return !document.querySelector('#reader-image-preview') && window.openedSource===document.querySelector('#figure') && window.actions===1"
        )
    }

    @MainActor private func imagePreviewFixture() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(
            WKUserScript(
                source: "window.paperSelection={selectObject:image=>window.quoted=image};"
                    + HTMLImagePreviewScript.source,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        let svg =
            "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='100'><rect width='200' height='100' fill='#7aaba0'/></svg>"
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!.base64EncodedString()
        web.loadHTMLString(
            "<html><head></head><body><button id='before' autofocus>Before</button><main id='reader'><img id='figure' src='data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())' width='200' height='100'><img id='bitmap' src='data:image/png;base64,\(png)' width='10' height='10'></main><div style='height:2000px'></div></body></html>",
            baseURL: nil)
        return web
    }

    @MainActor private func previewJS(_ web: WKWebView, _ source: String) async throws -> Any? {
        try await web.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .defaultClient)
    }

    @MainActor private func previewWait(_ web: WKWebView, _ condition: String, settle: Bool = true) async throws {
        for _ in 0..<200 {
            // Offscreen WebKit may pause animation clocks; settle only animations already created.
            if settle {
                _ = try? await previewJS(web, "for(const animation of document.getAnimations())animation.finish()")
            }
            if (try? await previewJS(web, condition)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "ImagePreviewTests", code: 1, userInfo: [NSLocalizedDescriptionKey: condition])
    }
#endif
