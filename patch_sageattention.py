import os

with open('setup.py') as f:
    content = f.read()

arch_list = os.environ['TORCH_CUDA_ARCH_LIST']
arch_set = '{' + ', '.join(f'"{a}"' for a in arch_list.split(';')) + '}'

old = '''compute_capabilities = set()
device_count = torch.cuda.device_count()
for i in range(device_count):
    major, minor = torch.cuda.get_device_capability(i)
    if major < 8:
        warnings.warn(f"skipping GPU {i} with compute capability {major}.{minor}")
        continue
    compute_capabilities.add(f"{major}.{minor}")'''
new = 'compute_capabilities = ' + arch_set

content = content.replace(old, new)

with open('setup.py', 'w') as f:
    f.write(content)
