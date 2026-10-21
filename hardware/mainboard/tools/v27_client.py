from v26_client import V26Control
from v27_protocol import status

class V27Control(V26Control):
    parse_status=staticmethod(status)
    LIMITS=V26Control.LIMITS+((0,2040),(0,2040),(1,2),(1,2))
    def apply_once(self,changes):
        current=self.snapshot()
        if current is None or current.get('firmware')!=27:
            raise RuntimeError('请先下载 v27 比特流；当前未收到 V27 扩展状态')
        return super().apply_once(changes)
