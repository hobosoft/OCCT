// Created on: 2011-09-20
// Created by: Sergey ZERCHANINOV
// Copyright (c) 2011-2012 OPEN CASCADE SAS
//
// The content of this file is subject to the Open CASCADE Technology Public
// License Version 6.5 (the "License"). You may not use the content of this file
// except in compliance with the License. Please obtain a copy of the License
// at http://www.opencascade.org and read it completely before using this file.
//
// The Initial Developer of the Original Code is Open CASCADE S.A.S., having its
// main offices at: 1, place des Freres Montgolfier, 78280 Guyancourt, France.
//
// The Original Code and all software distributed under the License is
// distributed on an "AS IS" basis, without warranty of any kind, and the
// Initial Developer hereby disclaims all such warranties, including without
// limitation, any warranties of merchantability, fitness for a particular
// purpose or non-infringement. Please see the License for the specific terms
// and conditions governing the rights and limitations under the License.


#include <InterfaceGraphic.hxx>

#include <OpenGl_Window.hxx>

#include <OpenGl_Context.hxx>
#include <OpenGl_Display.hxx>

#include <Aspect_GraphicDeviceDefinitionError.hxx>
#include <TCollection_AsciiString.hxx>

#include <GL/glu.h> // gluOrtho2D()

IMPLEMENT_STANDARD_HANDLE(OpenGl_Window,MMgt_TShared)
IMPLEMENT_STANDARD_RTTIEXT(OpenGl_Window,MMgt_TShared)

namespace
{
  static const TEL_COLOUR THE_DEFAULT_BG_COLOR = { { 0.F, 0.F, 0.F, 1.F } };

#if (defined(_WIN32) || defined(__WIN32__))
  static int find_pixel_format (HDC hDC, PIXELFORMATDESCRIPTOR* pfd, const Standard_Boolean dbuff)
  {
    PIXELFORMATDESCRIPTOR pfd0;
    memset (&pfd0, 0, sizeof (PIXELFORMATDESCRIPTOR));
    pfd0.nSize           = sizeof (PIXELFORMATDESCRIPTOR);
    pfd0.nVersion        = 1;
    pfd0.dwFlags         = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | (dbuff ? PFD_DOUBLEBUFFER : PFD_SUPPORT_GDI);
    pfd0.iPixelType      = PFD_TYPE_RGBA;
    pfd0.iLayerType      = PFD_MAIN_PLANE;

    int       iPixelFormat = 0;
    int       iGood = 0;
    const int cBits[] = { 32, 24 };
    const int dBits[] = { 32, 24, 16 };

    int i, j;
    for (i = 0; i < sizeof(dBits) / sizeof(int); i++)
    {
      pfd0.cDepthBits = dBits[i];
      iGood = 0;
      for (j = 0; j < sizeof(cBits) / sizeof(int); j++)
      {
        pfd0.cColorBits = cBits[j];
        iPixelFormat = ChoosePixelFormat (hDC, &pfd0);
        if (iPixelFormat)
        {
          pfd->cDepthBits = 0;
          pfd->cColorBits = 0;
          DescribePixelFormat (hDC, iPixelFormat, sizeof (PIXELFORMATDESCRIPTOR), pfd);
          if (pfd->cColorBits >= cBits[j] && pfd->cDepthBits >= dBits[i])
            break;
          if (iGood == 0)
            iGood = iPixelFormat;
        }
      }
      if (j < sizeof(cBits) / sizeof(int))
        break;
    }

    if (iPixelFormat == 0)
      iPixelFormat = iGood;

    return iPixelFormat;
  }
#else
  static Bool WaitForNotify (Display* theDisp, XEvent* theEv, char* theArg)
  {
    return (theEv->type == MapNotify) && (theEv->xmap.window == (Window )theArg);
  }
#endif

};

// =======================================================================
// function : OpenGl_Window
// purpose  :
// =======================================================================
OpenGl_Window::OpenGl_Window (const Handle(OpenGl_Display)& theDisplay,
                              const CALL_DEF_WINDOW&        theCWindow,
                              Aspect_RenderingContext       theGContext,
                              const Handle(OpenGl_Context)& theShareCtx)
: myDisplay (theDisplay),
  myGlContext (new OpenGl_Context()),
  myOwnGContext (theGContext == 0),
#if (defined(_WIN32) || defined(__WIN32__))
  mySysPalInUse (FALSE),
#endif
  myWidth ((Standard_Integer )theCWindow.dx),
  myHeight ((Standard_Integer )theCWindow.dy),
  myBgColor (THE_DEFAULT_BG_COLOR),
  myDither (theDisplay->Dither()),
  myBackDither (theDisplay->BackDither())
{
  myBgColor.rgb[0] = theCWindow.Background.r;
  myBgColor.rgb[1] = theCWindow.Background.g;
  myBgColor.rgb[2] = theCWindow.Background.b;

#if (defined(_WIN32) || defined(__WIN32__))
  HWND  aWindow   = (HWND )theCWindow.XWindow;
  HDC   aWindowDC = GetDC (aWindow);
  HGLRC aGContext = (HGLRC )theGContext;

  PIXELFORMATDESCRIPTOR pfd;
  int iPixelFormat = find_pixel_format (aWindowDC, &pfd, myDisplay->DBuffer());
  if (iPixelFormat == 0)
  {
    ReleaseDC (aWindow, aWindowDC);

    TCollection_AsciiString aMsg ("OpenGl_Window::CreateWindow: ChoosePixelFormat failed. Error code: ");
    aMsg += (int )GetLastError();
    Aspect_GraphicDeviceDefinitionError::Raise (aMsg.ToCString());
    return;
  }

  if (pfd.dwFlags & PFD_NEED_PALETTE)
  {
    WINDOW_DATA* wd = (WINDOW_DATA* )GetWindowLongPtr (aWindow, GWLP_USERDATA);

    mySysPalInUse = (pfd.dwFlags & PFD_NEED_SYSTEM_PALETTE) ? TRUE : FALSE;
    InterfaceGraphic_RealizePalette (aWindowDC, wd->hPal, FALSE, mySysPalInUse);
  }

  if (myDither)
    myDither = (pfd.cColorBits <= 8);

  if (myBackDither)
    myBackDither = (pfd.cColorBits <= 8);

  if (!SetPixelFormat (aWindowDC, iPixelFormat, &pfd))
  {
    ReleaseDC (aWindow, aWindowDC);

    TCollection_AsciiString aMsg("OpenGl_Window::CreateWindow: SetPixelFormat failed. Error code: ");
    aMsg += (int )GetLastError();
    Aspect_GraphicDeviceDefinitionError::Raise (aMsg.ToCString());
    return;
  }

  if (aGContext == NULL)
  {
    aGContext = wglCreateContext (aWindowDC);
    if (aGContext == NULL)
    {
      ReleaseDC (aWindow, aWindowDC);

      TCollection_AsciiString aMsg ("OpenGl_Window::CreateWindow: wglCreateContext failed. Error code: ");
      aMsg += (int )GetLastError();
      Aspect_GraphicDeviceDefinitionError::Raise (aMsg.ToCString());
      return;
    }
  }

  // all GL context within one OpenGl_GraphicDriver should be shared!
  if (!theShareCtx.IsNull() && wglShareLists ((HGLRC )theShareCtx->myGContext, aGContext) != TRUE)
  {
    TCollection_AsciiString aMsg ("OpenGl_Window::CreateWindow: wglShareLists failed. Error code: ");
    aMsg += (int )GetLastError();
    Aspect_GraphicDeviceDefinitionError::Raise (aMsg.ToCString());
    return;
  }

  myGlContext->Init ((Aspect_Handle )aWindow, (Aspect_Handle )aWindowDC, (Aspect_RenderingContext )aGContext);
#else
  WINDOW aParent = (WINDOW )theCWindow.XWindow;
  WINDOW aWindow = 0;
  DISPLAY* aDisp = (DISPLAY* )myDisplay->GetDisplay();
  GLXContext aGContext = (GLXContext )theGContext;

  XWindowAttributes wattr;
  XGetWindowAttributes (aDisp, aParent, &wattr);
  const int scr = DefaultScreen (aDisp);

  XVisualInfo* aVis = NULL;
  {
    unsigned long aVisInfoMask = VisualIDMask | VisualScreenMask;
    XVisualInfo aVisInfo;
    aVisInfo.visualid = wattr.visual->visualid;
    aVisInfo.screen   = scr;
    int aNbItems;
    aVis = XGetVisualInfo (aDisp, aVisInfoMask, &aVisInfo, &aNbItems);
  }

  if (!myOwnGContext)
  {
    if (aVis != NULL)
    {
      Aspect_GraphicDeviceDefinitionError::Raise ("OpenGl_Window::CreateWindow: XGetVisualInfo failed.");
      return;
    }

    aWindow = aParent;
  }
  else
  {
  #if defined(__linux) || defined(Linux)
    if (aVis != NULL)
    {
      // check Visual for OpenGl context's parameters compability
      int isGl = 0, isDoubleBuffer = 0, isRGBA = 0, aDepthSize = 0;

      if (glXGetConfig (aDisp, aVis, GLX_USE_GL, &isGl) != 0)
        isGl = 0;

      if (glXGetConfig (aDisp, aVis, GLX_RGBA, &isRGBA) != 0)
        isRGBA = 0;

      if (glXGetConfig (aDisp, aVis, GLX_DOUBLEBUFFER, &isDoubleBuffer) != 0)
        isDoubleBuffer = 0;

      if (glXGetConfig (aDisp, aVis, GLX_DEPTH_SIZE, &aDepthSize) != 0)
        aDepthSize = 0;

      if (!isGl || !aDepthSize || !isRGBA  || (isDoubleBuffer ? 1 : 0) != (myDisplay->DBuffer()? 1 : 0))
      {
        XFree (aVis);
        aVis = NULL;
      }
    }
  #endif

    if (aVis == NULL)
    {
      int anIter = 0;
      int anAttribs[11];
      anAttribs[anIter++] = GLX_RGBA;

      anAttribs[anIter++] = GLX_DEPTH_SIZE;
      anAttribs[anIter++] = 1;

      anAttribs[anIter++] = GLX_RED_SIZE;
      anAttribs[anIter++] = (wattr.depth <= 8) ? 0 : 1;

      anAttribs[anIter++] = GLX_GREEN_SIZE;
      anAttribs[anIter++] = (wattr.depth <= 8) ? 0 : 1;

      anAttribs[anIter++] = GLX_BLUE_SIZE;
      anAttribs[anIter++] = (wattr.depth <= 8) ? 0 : 1;

      if (myDisplay->DBuffer())
        anAttribs[anIter++] = GLX_DOUBLEBUFFER;

      anAttribs[anIter++] = None;

      aVis = glXChooseVisual (aDisp, scr, anAttribs);
      if (aVis == NULL)
      {
        Aspect_GraphicDeviceDefinitionError::Raise ("OpenGl_Window::CreateWindow: glXChooseVisual failed.");
        return;
      }
    }

    if (!theShareCtx.IsNull())
    {
      // ctx est une copie du previous
      aGContext = glXCreateContext (aDisp, aVis, (GLXContext )theShareCtx->myGContext, GL_TRUE);
    }
    else
    {
      aGContext = glXCreateContext (aDisp, aVis, NULL, GL_TRUE);
    }

    if (!aGContext)
    {
      Aspect_GraphicDeviceDefinitionError::Raise ("OpenGl_Window::CreateWindow: glXCreateContext failed.");
      return;
    }

    Colormap cmap = XCreateColormap (aDisp, aParent, aVis->visual, AllocNone);

    XColor color;
    color.red   = (unsigned short) (myBgColor.rgb[0] * 0xFFFF);
    color.green = (unsigned short) (myBgColor.rgb[1] * 0xFFFF);
    color.blue  = (unsigned short) (myBgColor.rgb[2] * 0xFFFF);
    color.flags = DoRed | DoGreen | DoBlue;
    XAllocColor (aDisp, cmap, &color);

    XSetWindowAttributes cwa;
    cwa.colormap         = cmap;
    cwa.event_mask       = StructureNotifyMask;
    cwa.border_pixel     = color.pixel;
    cwa.background_pixel = color.pixel;

    if (aVis->visualid == wattr.visual->visualid)
    {
      aWindow = aParent;
    }
    else
    {
      unsigned long mask = CWBackPixel | CWColormap | CWBorderPixel | CWEventMask;
      aWindow = XCreateWindow (aDisp, aParent, 0, 0, myWidth, myHeight, 0/*bw*/, aVis->depth, InputOutput, aVis->visual, mask, &cwa);
    }

    XSetWindowBackground (aDisp, aWindow, cwa.background_pixel);
    XClearWindow (aDisp, aWindow);

    if (aWindow != aParent)
    {
      XEvent anEvent;
      XMapWindow (aDisp, aWindow);
      XIfEvent (aDisp, &anEvent, WaitForNotify, (char* )aWindow);
    }
  }

  /*
  * Le BackDitherProp est utilise pour le clear du background
  * Pour eviter une difference de couleurs avec la couleur choisie
  * par l'application (XWindow) il faut desactiver le dithering
  * au dessus de 8 plans.
  *
  * Pour le DitherProp:
  * On cherchera a activer le Dithering que si le Visual a au moins
  * 8 plans pour le GLX_RED_SIZE. Le test est plus sur car on peut
  * avoir une profondeur superieure a 12 mais avoir besoin du dithering.
  * (Carte Impact avec GLX_RED_SIZE a 5 par exemple)
  */

  int aValue;
  glXGetConfig (aDisp, aVis, GLX_RED_SIZE, &aValue);

  if (myDither)
    myDither = (aValue < 8);

  if (myBackDither)
    myBackDither = (aVis->depth <= 8);

  XFree ((char* )aVis);

  myGlContext->Init ((Aspect_Drawable )aWindow, (Aspect_Display )myDisplay->GetDisplay(), (Aspect_RenderingContext )aGContext);
#endif
  myGlContext->Share (theShareCtx);

  Init();
}

// =======================================================================
// function : ~OpenGl_Window
// purpose  :
// =======================================================================
OpenGl_Window::~OpenGl_Window()
{
#if (defined(_WIN32) || defined(__WIN32__))
  HWND  aWindow   = (HWND  )myGlContext->myWindow;
  HDC   aWindowDC = (HDC   )myGlContext->myWindowDC;
  HGLRC aGContext = (HGLRC )myGlContext->myGContext;
  myGlContext.Nullify();

  if (myOwnGContext)
  {
    if (wglGetCurrentContext() != NULL)
    {
      wglDeleteContext (aGContext);
    }
    ReleaseDC (aWindow, aWindowDC);
  }
#else
  GLXDrawable aWindow   = (GLXDrawable )myGlContext->myWindow;
  Display*    aDisplay  = (Display*    )myGlContext->myDisplay;
  GLXContext  aGContext = (GLXContext  )myGlContext->myGContext;
  myGlContext.Nullify();

  if (aDisplay != NULL && myOwnGContext)
  {
    // FSXXX sync necessary if non-direct rendering
    glXWaitGL();
    glXDestroyContext (aDisplay, aGContext);
  }
#endif
}

// =======================================================================
// function : Activate
// purpose  :
// =======================================================================
Standard_Boolean OpenGl_Window::Activate()
{
  return myGlContext->MakeCurrent();
}

// =======================================================================
// function : Resize
// purpose  : call_subr_resize
// =======================================================================
void OpenGl_Window::Resize (const CALL_DEF_WINDOW& theCWindow)
{
  DISPLAY* aDisp = (DISPLAY* )myDisplay->GetDisplay();
  if (aDisp == NULL)
    return;

  // If the size is not changed - do nothing
  if ((myWidth == theCWindow.dx) && (myHeight == theCWindow.dy))
    return;

  myWidth  = (Standard_Integer )theCWindow.dx;
  myHeight = (Standard_Integer )theCWindow.dy;

#if (!defined(_WIN32) && !defined(__WIN32__))
  XResizeWindow (aDisp, myGlContext->myWindow, (unsigned int )myWidth, (unsigned int )myHeight);
  XSync (aDisp, False);
#endif

  Init();
}

// =======================================================================
// function : ReadDepths
// purpose  : TelReadDepths
// =======================================================================
void OpenGl_Window::ReadDepths (const Standard_Integer theX,     const Standard_Integer theY,
                                const Standard_Integer theWidth, const Standard_Integer theHeight,
                                float* theDepths)
{
  if (theDepths == NULL || !Activate())
    return;

  glMatrixMode (GL_PROJECTION);
  glLoadIdentity();
  gluOrtho2D (0.0, (GLdouble )myWidth, 0.0, (GLdouble )myHeight);
  glMatrixMode (GL_MODELVIEW);
  glLoadIdentity();

  glRasterPos2i (theX, theY);
  DisableFeatures();
  glReadPixels (theX, theY, theWidth, theHeight, GL_DEPTH_COMPONENT, GL_FLOAT, theDepths);
  EnableFeatures();
}

// =======================================================================
// function : SetBackgroundColor
// purpose  : call_subr_set_background
// =======================================================================
void OpenGl_Window::SetBackgroundColor (const Standard_ShortReal theR,
                                        const Standard_ShortReal theG,
                                        const Standard_ShortReal theB)
{
  myBgColor.rgb[0] = theR;
  myBgColor.rgb[1] = theG;
  myBgColor.rgb[2] = theB;
}

// =======================================================================
// function : Init
// purpose  :
// =======================================================================
void OpenGl_Window::Init()
{
  if (!Activate())
    return;

#if (defined(_WIN32) || defined(__WIN32__))
  RECT cr;
  GetClientRect ((HWND )myGlContext->myWindow, &cr);
  myWidth  = cr.right - cr.left;
  myHeight = cr.bottom - cr.top;
#else
  Window aRootWin;
  int aDummy;
  unsigned int aDummyU;
  unsigned int aNewWidth  = 0;
  unsigned int aNewHeight = 0;
  DISPLAY* aDisp = (DISPLAY* )myDisplay->GetDisplay();
  XGetGeometry (aDisp, myGlContext->myWindow, &aRootWin, &aDummy, &aDummy, &aNewWidth, &aNewHeight, &aDummyU, &aDummyU);
  myWidth  = aNewWidth;
  myHeight = aNewHeight;
#endif

  glMatrixMode (GL_MODELVIEW);
  glViewport (0, 0, myWidth, myHeight);

  glDisable (GL_SCISSOR_TEST);
  glDrawBuffer (GL_BACK);
}

// =======================================================================
// function : EnablePolygonOffset
// purpose  : call_subr_enable_polygon_offset
// =======================================================================
void OpenGl_Window::EnablePolygonOffset() const
{
  Standard_ShortReal aFactor, aUnits;
  myDisplay->PolygonOffset (aFactor, aUnits);
  glPolygonOffset (aFactor, aUnits);
  glEnable (GL_POLYGON_OFFSET_FILL);
}

// =======================================================================
// function : DisablePolygonOffset
// purpose  : call_subr_disable_polygon_offset
// =======================================================================
void OpenGl_Window::DisablePolygonOffset() const
{
  glDisable (GL_POLYGON_OFFSET_FILL);
}

// =======================================================================
// function : EnableFeatures
// purpose  :
// =======================================================================
void OpenGl_Window::EnableFeatures() const
{
  /*glPixelTransferi (GL_MAP_COLOR, GL_TRUE);*/

  if (myDither)
    glEnable (GL_DITHER);
  else
    glDisable (GL_DITHER);
}

// =======================================================================
// function : DisableFeatures
// purpose  :
// =======================================================================
void OpenGl_Window::DisableFeatures() const
{
  glDisable (GL_DITHER);
  glPixelTransferi (GL_MAP_COLOR, GL_FALSE);

  /*
  * Disable stuff that's likely to slow down glDrawPixels.
  * (Omit as much of this as possible, when you know in advance
  * that the OpenGL state will already be set correctly.)
  */
  glDisable(GL_ALPHA_TEST);
  glDisable(GL_BLEND);
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_FOG);
  glDisable(GL_LIGHTING);

  glDisable(GL_LOGIC_OP);
  glDisable(GL_STENCIL_TEST);
  glDisable(GL_TEXTURE_1D);
  glDisable(GL_TEXTURE_2D);
  glPixelTransferi(GL_MAP_COLOR, GL_FALSE);
  glPixelTransferi(GL_RED_SCALE, 1);
  glPixelTransferi(GL_RED_BIAS, 0);
  glPixelTransferi(GL_GREEN_SCALE, 1);
  glPixelTransferi(GL_GREEN_BIAS, 0);
  glPixelTransferi(GL_BLUE_SCALE, 1);
  glPixelTransferi(GL_BLUE_BIAS, 0);
  glPixelTransferi(GL_ALPHA_SCALE, 1);
  glPixelTransferi(GL_ALPHA_BIAS, 0);

  /*
  * Disable extensions that could slow down glDrawPixels.
  * (Actually, you should check for the presence of the proper
  * extension before making these calls.  I've omitted that
  * code for simplicity.)
  */

#ifdef GL_EXT_convolution
  glDisable(GL_CONVOLUTION_1D_EXT);
  glDisable(GL_CONVOLUTION_2D_EXT);
  glDisable(GL_SEPARABLE_2D_EXT);
#endif

#ifdef GL_EXT_histogram
  glDisable(GL_HISTOGRAM_EXT);
  glDisable(GL_MINMAX_EXT);
#endif

#ifdef GL_EXT_texture3D
  glDisable(GL_TEXTURE_3D_EXT);
#endif
}

// =======================================================================
// function : MakeFrontBufCurrent
// purpose  : TelMakeFrontBufCurrent
// =======================================================================
void OpenGl_Window::MakeFrontBufCurrent() const
{
  glDrawBuffer (GL_FRONT);
}

// =======================================================================
// function : MakeBackBufCurrent
// purpose  : TelMakeBackBufCurrent
// =======================================================================
void OpenGl_Window::MakeBackBufCurrent() const
{
  glDrawBuffer (GL_BACK);
}

// =======================================================================
// function : MakeFrontAndBackBufCurrent
// purpose  : TelMakeFrontAndBackBufCurrent
// =======================================================================
void OpenGl_Window::MakeFrontAndBackBufCurrent() const
{
  glDrawBuffer (GL_FRONT_AND_BACK);
}

// =======================================================================
// function : GetGContext
// purpose  :
// =======================================================================
GLCONTEXT OpenGl_Window::GetGContext() const
{
  return (GLCONTEXT )myGlContext->myGContext;
}
