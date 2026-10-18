# Ellipse

A framework for building desktop applications and tools.

Ellipse uses SDL3, and the nim programming language, it provides a simple api for creating windows and rendering on them. The rendering uses SDL3 gpu.

Ellipse has a powerful gui framework, designed to be modular and data oriented. The gui is designed to work in terminals and in a graphical window, you can use your tool in the tty or in a graphical session.

<img width="1286" height="726" alt="image" src="https://github.com/user-attachments/assets/9d2a6c0c-3318-4e77-8660-4c8112132360" />

<img width="1251" height="675" alt="image" src="https://github.com/user-attachments/assets/c8313170-8ef7-43f7-848f-3f017928d969" />

Ellipse comes with a simple config and tool oriented scripting language, config oriented because it has a simple
tree syntex, similar to s-expressions but using indentation instead of parenthesis in most places. Tool oriented 
as in its designed for building gui tools and system scripts.

```owl
fun hello-world msg:
  echo "\(msg) world!"
hell-world "test"

joe = {}:
  name = "Joe"
  age = 45

echo (+ joe.age 100)

fun word next what (optional = false):
    arg = (next)
    when (and (= arg nothing) (not optional)):
        fail (concat "missing " what)
    when (and (<> arg nothing) (<> arg.type "cmd")):
        fail (concat "expected " what ", not the option " arg.flag)
    if (= arg nothing):
        nothing
        arg.name
```
