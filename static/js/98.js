document.addEventListener('DOMContentLoaded', function() {
    // -------------------------------------------------------------------------
    // Radio Button Functionality
    // -------------------------------------------------------------------------
    function applySettings() {
        const currentHost = window.location.hostname;
        const hostParts = currentHost.split('.');
        const baseHost = hostParts.slice(1).join('.');
        const selectedRadio = document.querySelector('input[name="ipversion"]:checked');

        let targetUrl = "";
        if (selectedRadio) {
            switch (selectedRadio.value) {
                case "auto": targetUrl = `https://ip.${baseHost}/98`; break;
                case "ip4": targetUrl = `https://ip4.${baseHost}/98`; break;
                case "ip6": targetUrl = `https://ip6.${baseHost}/98`; break;
            }
            window.location.href = targetUrl;
        }
    }

    // Pre-select the appropriate radio button based on the current URL
    const currentUrl = window.location.href;
    const radio1 = document.getElementById("radio1");
    const radio2 = document.getElementById("radio2");
    const radio3 = document.getElementById("radio3");

    if (radio1 && radio2 && radio3) {
        if (currentUrl.includes("ip4.")) {
            radio2.checked = true;
        } else if (currentUrl.includes("ip6.")) {
            radio3.checked = true;
        } else {
            radio1.checked = true;
        }
    }

    // -------------------------------------------------------------------------
    // Status Bar Clock
    // -------------------------------------------------------------------------
    function startTime() {
        const today = new Date();
        let h = today.getHours();
        let m = today.getMinutes();
        let s = today.getSeconds();
        m = checkTime(m);
        s = checkTime(s);
        document.getElementById('clock').innerHTML = h + ":" + m + ":" + s;
        setTimeout(startTime, 1000);
    }

    function checkTime(i) {
        if (i < 10) { i = "0" + i };
        return i;
    }

    // -------------------------------------------------------------------------
    // Initial Scale and Resize Handling
    // -------------------------------------------------------------------------
    function setInitialScale() {
        const windowWidth = 360;
        const screenWidth = window.innerWidth;
        const initialScale = screenWidth / windowWidth;
        document.querySelector('meta[name="viewport"]').setAttribute('content', `width=device-width, initial-scale=${initialScale}`);
    }

    // Call setInitialScale and startTime on page load
    setInitialScale();
    startTime();

    // Event listener for window resize
    window.addEventListener('resize', setInitialScale);

    // -------------------------------------------------------------------------
    // Button Event Listeners and Window Dragging
    // -------------------------------------------------------------------------
    const okButton = document.getElementById('ok-button');
	const cancelButton = document.getElementById('cancel-button');
    const applyButton = document.getElementById('apply-button');
    const windowDiv = document.getElementById('winipcfg-window');
    const maximizeButton = document.getElementById('maximize-button');
    const minimizeButton = document.getElementById('minimize-button');
    const closeButton = document.getElementById('close-button');
	const titleBar = document.querySelector('.title-bar');
    const winipcfgIcon = document.getElementById('winipcfg-icon'); // Icon container
	const iconComponents = document.querySelectorAll('.icon-component'); //all icon components class

    let isMaximized = false; // Declare isMaximized in the main function scope
	let isMinimized = false; // Track minimize state
    let isDragging = false;
    let offsetX, offsetY;

    // Button event listeners
    okButton.addEventListener('click', applySettings);
    applyButton.addEventListener('click', applySettings);
	if (cancelButton) {cancelButton.addEventListener('click', function() {window.location.href = '/'; }); }
	if (closeButton) {
        closeButton.addEventListener('click', function() {
            //window.location.href = '/';
			if (!isMinimized) {
                // Minimize
                windowDiv.style.display = 'none'; // Hide window
                winipcfgIcon.style.display = 'block'; // Show icon
                isMinimized = true;
            } else {
                // Restore
                windowDiv.style.display = 'block'; // Show window
                winipcfgIcon.style.display = 'none'; // Hide icon
                isMinimized = false;
            }
        });
    }

    if (maximizeButton) {
        maximizeButton.addEventListener('click', function() {
            if (!isMaximized) {
                // Maximize
                const targetWidth = windowDiv.offsetWidth;
                const targetHeight = windowDiv.offsetHeight;
                const windowWidth = window.innerWidth;
                const windowHeight = window.innerHeight;
                const scaleX = windowWidth / targetWidth;
                const scaleY = windowHeight / targetHeight;
                const scale = Math.floor(Math.min(scaleX, scaleY));

                if (scale <= 1) {
                    return;
                }

                const scaledHeight = targetHeight * scale;
                const heightDifference = scaledHeight - targetHeight;
                const translateY = heightDifference / scale / 2;

                windowDiv.style.transform = `scale(${scale}) translate(0, ${translateY}px)`;
                maximizeButton.setAttribute('aria-label', 'Restore');
                isMaximized = true;
            } else {
                // Restore
                windowDiv.style.transform = `scale(1) translate(0, 0)`;
                maximizeButton.setAttribute('aria-label', 'Maximize');
                isMaximized = false;
            }
            // Ensure window is visible and icon is hidden
            windowDiv.style.display = 'block';
            winipcfgIcon.style.display = 'none';
            isMinimized = false;
        });
    }

    // Minimize Button Logic
    if (minimizeButton) {
        minimizeButton.addEventListener('click', function() {
            if (!isMinimized) {
                // Minimize (Animated)
                const iconRect = winipcfgIcon.getBoundingClientRect();
                const windowRect = windowDiv.getBoundingClientRect();

                const translateX = iconRect.left - windowRect.left;
                const translateY = iconRect.top - windowRect.top;

                windowDiv.style.transformOrigin = 'top left'; // Set transform origin
                windowDiv.style.transform = `translate(${translateX}px, ${translateY}px) scale(0.1)`;
                windowDiv.style.opacity = '0';

                setTimeout(function() {
                    windowDiv.style.display = 'none';
                    winipcfgIcon.style.display = 'block';
                    setTimeout(function() {
                        winipcfgIcon.classList.add('restored');
                    }, 10);
                }, 300); // Match transition duration
                isMinimized = true;
            } else {
                // Restore (Animated)
                winipcfgIcon.classList.remove('restored');
                windowDiv.style.display = 'block';
                setTimeout(function() {
                    windowDiv.style.transform = 'scale(1)';
                    windowDiv.style.opacity = '1';
                    windowDiv.style.transformOrigin = 'center';
                },10);
                setTimeout(function() {
                    winipcfgIcon.style.display = 'none';
                }, 300);
                isMinimized = false;
            }
        });
    }

    // Restore on Double-Click
    winipcfgIcon.addEventListener('dblclick', function() {
        if (isMinimized) {
            winipcfgIcon.classList.remove('restored');
            windowDiv.style.display = 'block';
            setTimeout(function() {
                if (isMaximized) {
                    // Restore maximized state
                    const targetWidth = windowDiv.offsetWidth;
                    const targetHeight = windowDiv.offsetHeight;
                    const windowWidth = window.innerWidth;
                    const windowHeight = window.innerHeight;
                    const scaleX = windowWidth / targetWidth;
                    const scaleY = windowHeight / targetHeight;
                    const scale = Math.floor(Math.min(scaleX, scaleY));

                    const scaledHeight = targetHeight * scale;
                    const heightDifference = scaledHeight - targetHeight;
                    const translateY = heightDifference / scale / 2;

                    windowDiv.style.transform = `scale(${scale}) translate(0, ${translateY}px)`;
					windowDiv.style.opacity = '1';
                    maximizeButton.setAttribute('aria-label', 'Restore');
                } else {
                    // Restore normal state
                    windowDiv.style.transform = 'scale(1)';
                    windowDiv.style.opacity = '1';
                    windowDiv.style.transformOrigin = 'center';
                    maximizeButton.setAttribute('aria-label', 'Maximize');
                }
            },10);
            setTimeout(function() {
                winipcfgIcon.style.display = 'none';
            }, 300);
            isMinimized = false;
        }
    });
	// Single-Click Overlay
	function iconSelection() {
		winipcfgIcon.classList.add('selected');
			// Remove overlay on next click anywhere else
			function removeOverlay(event) {
				let isIconComponent = false;
				event.composedPath().forEach(function(element){
					if (element.classList && element.classList.contains('icon-component')){
						isIconComponent = true;
					}
				});
				if (event.target !== winipcfgIcon && !isIconComponent) {
					winipcfgIcon.classList.remove('selected');
					document.removeEventListener('click', removeOverlay);
				}
			}

			document.addEventListener('click', removeOverlay);
		}
	// link iconselection to icon
	if (iconComponents){
		iconComponents.forEach(function(iconComponent) {
			iconComponent.addEventListener('click', iconSelection);
		});
	}


	// Reusable drag function
    function makeDraggable(element, dragHandle) { // Add dragHandle parameter
        let isDragging = false;
        let offsetX, offsetY;
		if (dragHandle.id.includes('icon')) {
			iconSelection();
		}
        dragHandle.addEventListener('mousedown', function(event) { // Use dragHandle
            isDragging = true;
            offsetX = event.clientX - element.offsetLeft;
            offsetY = event.clientY - element.offsetTop;
            dragHandle.style.cursor = 'auto'; // Change cursor on dragHandle
        });

        document.addEventListener('mousemove', function(event) {
            if (!isDragging) return;

            const x = event.clientX - offsetX;
            const y = event.clientY - offsetY;

            element.style.left = x + 'px';
            element.style.top = y + 'px';
        });

        document.addEventListener('mouseup', function() {
            isDragging = false;
            dragHandle.style.cursor = 'auto'; // Change cursor on dragHandle
        });

        dragHandle.addEventListener('dragstart', function(event) { // Use dragHandle
            event.preventDefault();
        });
    }
	// Make window draggable by title bar
    makeDraggable(windowDiv, titleBar); // Pass windowDiv and titleBar

    // Make icon draggable
    makeDraggable(winipcfgIcon, winipcfgIcon); // Icon is draggable by itself
});
