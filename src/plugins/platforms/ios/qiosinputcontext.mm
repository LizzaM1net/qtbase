// Copyright (C) 2020 The Qt Company Ltd.
// SPDX-License-Identifier: LicenseRef-Qt-Commercial OR LGPL-3.0-only OR GPL-2.0-only OR GPL-3.0-only

#include "qiosinputcontext.h"

#import <UIKit/UIGestureRecognizerSubclass.h>

#include "qiosglobal.h"
#include "qiosintegration.h"
#include "qiosscreen.h"
#include "qiostextresponder.h"
#include "qiosviewcontroller.h"
#include "qioswindow.h"
#include "quiview.h"

#include <QtCore/private/qcore_mac_p.h>

#include <QGuiApplication>
#include <QtGui/private/qwindow_p.h>

#include <QtCore/qpointer.h>

// -------------------------------------------------------------------------

static QUIView *focusView()
{
    return qApp->focusWindow() ?
        reinterpret_cast<QUIView *>(qApp->focusWindow()->winId()) : 0;
}

// -------------------------------------------------------------------------

@interface QIOSLocaleListener : NSObject
@end

@implementation QIOSLocaleListener

- (instancetype)init
{
    if (self = [super init]) {
        NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
        [notificationCenter addObserver:self
            selector:@selector(localeDidChange:)
            name:NSCurrentLocaleDidChangeNotification object:nil];
    }

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (void)localeDidChange:(NSNotification *)notification
{
    Q_UNUSED(notification);
    QIOSInputContext::instance()->emitLocaleChanged();
}

@end

// -------------------------------------------------------------------------

@interface QIOSKeyboardListener : NSObject
@end

@implementation QIOSKeyboardListener

- (instancetype)init
{
    if (self = [super init]) {
#ifndef Q_OS_TVOS
        NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];

        [notificationCenter addObserver:self
            selector:@selector(keyboardWillOrDidChange:)
            name:UIKeyboardWillShowNotification object:nil];
        [notificationCenter addObserver:self
            selector:@selector(keyboardWillOrDidChange:)
            name:UIKeyboardDidShowNotification object:nil];
        [notificationCenter addObserver:self
            selector:@selector(keyboardWillOrDidChange:)
            name:UIKeyboardWillHideNotification object:nil];
        [notificationCenter addObserver:self
            selector:@selector(keyboardWillOrDidChange:)
            name:UIKeyboardDidHideNotification object:nil];
        [notificationCenter addObserver:self
            selector:@selector(keyboardWillOrDidChange:)
            name:UIKeyboardDidChangeFrameNotification object:nil];
#endif
    }

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [super dealloc];
}

- (void)keyboardWillOrDidChange:(NSNotification *)notification
{
    QIOSInputContext::instance()->updateKeyboardState(notification);
}

@end

// -------------------------------------------------------------------------

QT_BEGIN_NAMESPACE

Qt::InputMethodQueries ImeState::update(Qt::InputMethodQueries properties)
{
    if (!properties)
        return {};

    QInputMethodQueryEvent newState(properties);

    // Update the focus object that the new state is based on
    focusObject = qApp ? qApp->focusObject() : 0;

    if (focusObject)
        QCoreApplication::sendEvent(focusObject, &newState);

    Qt::InputMethodQueries updatedProperties;
    for (uint i = 0; i < (sizeof(Qt::ImQueryAll) * CHAR_BIT); ++i) {
        if (Qt::InputMethodQuery property = Qt::InputMethodQuery(int(properties & (1 << i)))) {
            if (newState.value(property) != currentState.value(property)) {
                updatedProperties |= property;
                currentState.setValue(property, newState.value(property));
            }
        }
    }

    return updatedProperties;
}

// -------------------------------------------------------------------------

QIOSInputContext *QIOSInputContext::instance()
{
    return static_cast<QIOSInputContext *>(QIOSIntegration::instance()->inputContext());
}

QIOSInputContext::QIOSInputContext()
    : QPlatformInputContext()
    , m_localeListener([QIOSLocaleListener new])
    , m_keyboardListener([QIOSKeyboardListener new])
    , m_textResponder(0)
{
    Q_ASSERT(!qGuiApp->focusWindow());
    connect(qGuiApp, &QGuiApplication::focusWindowChanged, this, &QIOSInputContext::focusWindowChanged);
}

QIOSInputContext::~QIOSInputContext()
{
    [m_localeListener release];
    [m_keyboardListener release];

    [m_textResponder release];
}

void QIOSInputContext::showInputPanel()
{
    // No-op, keyboard controlled fully by platform based on focus
    qImDebug("can't show virtual keyboard without a focus object, ignoring");
}

void QIOSInputContext::hideInputPanel()
{
    if (![m_textResponder isFirstResponder]) {
        qImDebug("QIOSTextInputResponder is not first responder, ignoring");
        return;
    }

    if (qGuiApp->focusObject() != m_imeState.focusObject) {
        qImDebug("current focus object does not match IM state, likely hiding from focusOut event, so ignoring");
        return;
    }

    qImDebug("hiding VKB as requested by QInputMethod::hide()");
    [m_textResponder resignFirstResponder];
}

void QIOSInputContext::clearCurrentFocusObject()
{
    if (QWindow *focusWindow = qApp->focusWindow())
        static_cast<QWindowPrivate *>(QObjectPrivate::get(focusWindow))->clearFocusObject();
}

// -------------------------------------------------------------------------

void QIOSInputContext::updateKeyboardState(NSNotification *notification)
{
#if defined(Q_OS_TVOS) || defined(Q_OS_VISIONOS)
    Q_UNUSED(notification);
#else
    static CGRect currentKeyboardRect = CGRectZero;

    KeyboardState previousState = m_keyboardState;

    if (notification) {
        NSDictionary *userInfo = [notification userInfo];

        CGRect frameBegin = [[userInfo objectForKey:UIKeyboardFrameBeginUserInfoKey] CGRectValue];
        CGRect frameEnd = [[userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];

        bool atEndOfKeyboardTransition = [notification.name rangeOfString:@"Did"].location != NSNotFound;

        currentKeyboardRect = atEndOfKeyboardTransition ? frameEnd : frameBegin;

        // The isInputPanelVisible() property is based on whether or not the virtual keyboard
        // is visible on screen, and does not follow the logic of the iOS WillShow and WillHide
        // notifications which are not emitted for undocked keyboards, and are buggy when dealing
        // with input-accessory-views. The reason for using frameEnd here (the future state),
        // instead of the current state reflected in frameBegin, is that QInputMethod::isVisible()
        // is documented to reflect the future state in the case of animated transitions.
        m_keyboardState.keyboardVisible = !CGRectIsEmpty(UIScreen.mainScreen.bounds) &&
            !CGRectIsEmpty(frameEnd) && CGRectIntersectsRect(frameEnd, UIScreen.mainScreen.bounds);

        // Used for auto-scroller, and will be used for animation-signal in the future
        m_keyboardState.keyboardEndRect = frameEnd;

        if (m_keyboardState.animationCurve < 0) {
            // We only set the animation curve the first time it has a valid value, since iOS will sometimes report
            // an invalid animation curve even if the keyboard is animating, and we don't want to overwrite the
            // curve in that case.
            m_keyboardState.animationCurve = UIViewAnimationCurve([[userInfo objectForKey:UIKeyboardAnimationCurveUserInfoKey] integerValue]);
        }

        m_keyboardState.animationDuration = [[userInfo objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
        m_keyboardState.keyboardAnimating = m_keyboardState.animationDuration > 0 && !atEndOfKeyboardTransition;

        qImDebug() << qPrintable(QString::fromNSString(notification.name)) << "from" << QRectF::fromCGRect(frameBegin) << "to" << QRectF::fromCGRect(frameEnd)
                   << "(curve =" << m_keyboardState.animationCurve << "duration =" << m_keyboardState.animationDuration << "s)";
    } else {
        qImDebug("No notification to update keyboard state based on, just updating keyboard rect");
    }

    if (!focusView() || CGRectIsEmpty(currentKeyboardRect))
        m_keyboardState.keyboardRect = QRectF();
    else // QInputmethod::keyboardRectangle() is documented to be in window coordinates.
        m_keyboardState.keyboardRect = QRectF::fromCGRect([focusView() convertRect:currentKeyboardRect fromView:nil]);

    // Emit for all changed properties
    if (m_keyboardState.keyboardVisible != previousState.keyboardVisible)
        emitInputPanelVisibleChanged();
    if (m_keyboardState.keyboardAnimating != previousState.keyboardAnimating)
        emitAnimatingChanged();
    if (m_keyboardState.keyboardRect != previousState.keyboardRect)
        emitKeyboardRectChanged();
#endif
}

bool QIOSInputContext::isInputPanelVisible() const
{
    return m_keyboardState.keyboardVisible;
}

bool QIOSInputContext::isAnimating() const
{
    return m_keyboardState.keyboardAnimating;
}

QRectF QIOSInputContext::keyboardRect() const
{
    return m_keyboardState.keyboardRect;
}

// -------------------------------------------------------------------------

void QIOSInputContext::setFocusObject(QObject *focusObject)
{
    Q_UNUSED(focusObject);

    qImDebug() << "new focus object =" << focusObject;

    if (focusObject == m_imeState.focusObject) {
        qImDebug("same focus object as last update, skipping reset");
        return;
    }

    reset();
}

void QIOSInputContext::focusWindowChanged(QWindow *focusWindow)
{
    qImDebug() << "new focus window =" << focusWindow;

    reset();

    // The keyboard rectangle depend on the focus window, so
    // we need to re-evaluate the keyboard state.
    updateKeyboardState();
}

/*!
    Called by the input item to inform the platform input methods when there has been
    state changes in editor's input method query attributes. When calling the function
    \a queries parameter has to be used to tell what has changes, which input method
    can use to make queries for attributes it's interested with QInputMethodQueryEvent.
*/
void QIOSInputContext::update(Qt::InputMethodQueries updatedProperties)
{
    qImDebug() << "fw =" << qApp->focusWindow() << "fo =" << qApp->focusObject();

    // Changes to the focus object should always result in a call to setFocusObject(),
    // triggering a reset() which will update all the properties based on the new
    // focus object. We try to detect code paths that fail this assertion and smooth
    // over the situation by doing a manual update of the focus object.
    if (qApp->focusObject() != m_imeState.focusObject && updatedProperties != Qt::ImQueryAll) {
        qCWarning(lcQpaInputMethods).verbosity(0) << "Updating input context" << updatedProperties
            << "with last reported focus object" << m_imeState.focusObject
            << "but qGuiApp reports" << qApp->focusObject()
            << "which means someone failed to call QPlatformInputContext::setFocusObject()";
        setFocusObject(qApp->focusObject());
        return;
    }

    // Mask for properties that we are interested in and see if any of them changed
    updatedProperties &= (Qt::ImEnabled | Qt::ImHints | Qt::ImQueryInput | Qt::ImEnterKeyType | Qt::ImPlatformData | Qt::ImReadOnly);

    // Perform update first, so we can trust the value of inputMethodAccepted()
    Qt::InputMethodQueries changedProperties = m_imeState.update(updatedProperties);

    const bool inputIsReadOnly = m_imeState.currentState.value(Qt::ImReadOnly).toBool();

    if (inputMethodAccepted() || inputIsReadOnly) {
        if (!m_textResponder || [m_textResponder needsKeyboardReconfigure:changedProperties]) {
            [m_textResponder autorelease];
            if (inputIsReadOnly) {
                qImDebug("creating new read-only text responder");
                m_textResponder = [[QIOSTextResponder alloc] initWithInputContext:this];
            } else {
                qImDebug("creating new read/write text responder");
                m_textResponder = [[QIOSTextInputResponder alloc] initWithInputContext:this];
            }
        } else {
            qImDebug("no need to reconfigure keyboard, just notifying input delegate");
            [m_textResponder notifyInputDelegate:changedProperties];
        }

        if (![m_textResponder isFirstResponder]) {
            qImDebug("IM enabled, making text responder first responder");
            [m_textResponder becomeFirstResponder];
        }
    } else if ([m_textResponder isFirstResponder]) {
        qImDebug("IM not enabled, resigning text responder as first responder");
        [m_textResponder resignFirstResponder];
    }
}

bool QIOSInputContext::inputMethodAccepted() const
{
    // The IM enablement state is based on the last call to update()
    bool lastKnownImEnablementState = m_imeState.currentState.value(Qt::ImEnabled).toBool();

#if !defined(QT_NO_DEBUG)
    // QPlatformInputContext keeps a cached value of the current IM enablement state that is
    // updated by QGuiApplication when the current focus object changes, or by QInputMethod's
    // update() function. If the focus object changes, but the change is not propagated as
    // a signal to QGuiApplication due to bugs in the widget/graphicsview/qml stack, we'll
    // end up with a stale value for QPlatformInputContext::inputMethodAccepted(). To be on
    // the safe side we always use our own cached value to decide if IM is enabled, and try
    // to detect the case where the two values are out of sync.
    if (lastKnownImEnablementState != QPlatformInputContext::inputMethodAccepted())
        qWarning("QPlatformInputContext::inputMethodAccepted() does not match actual focus object IM enablement!");
#endif

    return lastKnownImEnablementState;
}

/*!
    Called by the input item to reset the input method state.
*/
void QIOSInputContext::reset()
{
    qImDebug("releasing text responder");

    // UIKit will sometimes, for unknown reasons, unset the input delegate on the
    // current text responder. This seems to happen as a result of us calling
    // [self.inputDelegate textDidChange:self] from [m_textResponder reset].
    // But it won't be set to nil directly, only after a character is typed on
    // the input panel after the reset. This strange behavior seems to be related
    // to us overriding [QUIView setInteraction] to ignore UITextInteraction. If we
    // didn't do that, the delegate would be kept. But not overriding that function
    // has its own share of issues, so it seems better to keep that way for now.
    // Instead, we choose to recreate the text responder as a brute-force solution
    // until we have better knowledge of what is going on (or implement the new
    // UITextInteraction protocol).
    const auto oldResponder = m_textResponder;
    [m_textResponder reset];
    [m_textResponder autorelease];
    m_textResponder = nullptr;

    update(Qt::ImQueryAll);

    // If update() didn't end up creating a new text responder, oldResponder will still be
    // the first responder. In that case we need to resign it, so that the input panel hides.
    // (the input panel will apparently not hide if the first responder is only released).
    if ([oldResponder isFirstResponder]) {
        qImDebug("IM not enabled, resigning autoreleased text responder as first responder");
        [oldResponder resignFirstResponder];
    }
}

/*!
    Commits the word user is currently composing to the editor. The function is
    mostly needed by the input methods with text prediction features and by the
    methods where the script used for typing characters is different from the
    script that actually gets appended to the editor. Any kind of action that
    interrupts the text composing needs to flush the composing state by calling the
    commit() function, for example when the cursor is moved elsewhere.
*/
void QIOSInputContext::commit()
{
    qImDebug("unmarking text");
    [m_textResponder commit];
}

QLocale QIOSInputContext::locale() const
{
    return QLocale(QString::fromNSString([[NSLocale currentLocale] objectForKey:NSLocaleIdentifier]));
}

QT_END_NAMESPACE
