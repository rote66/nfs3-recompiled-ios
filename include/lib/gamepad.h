#ifndef LIB_GAMEPAD_H_
#define LIB_GAMEPAD_H_

#include <lib/winapp.h>
#include <lib/platform.h>


namespace win32
{

enum InputType
{
    InputType_Keyboard,
    InputType_Mouse,
    InputType_Gamepad
};

class Input : public GenericResource
{
public:
    virtual x86::reg32 getButtonCount() const;
    virtual x86::reg32 getAxesCount() const;
    static void poll();
};

class Keyboard : public Input
{
};

class Mouse : public Input
{
};

struct GamepadState
{
    x86::reg64  buttons;
    x86::sreg16 axes[10];
    x86::reg8   hats[10];
};

class Gamepad : public Input
{
public:
    Gamepad(x86::reg32 gamepadIndex);
    ~Gamepad();

    virtual x86::reg32 getButtonCount() const;
    virtual x86::reg32 getAxesCount() const;

    static x86::reg32 getCount();

    GamepadState getState() const;
    static void updateKeys();
#ifdef NFS_IOS
    unsigned index() const { return m_index; }
#endif
private:
#ifdef NFS_IOS
    unsigned m_index;
#else
    SDL_Joystick* m_joystick;
#endif
};

}

#endif
