import 'package:flutter/material.dart';
import '../services/linux_interactivity.dart';
import '../models/compaign_model.dart';
import '../views/campaign_view.dart' show VideoPlaylistWidget;

class LinuxTriggerSurface extends StatelessWidget {
  final Widget child;
  const LinuxTriggerSurface({super.key,required this.child});
  @override
  Widget build(BuildContext context) {
    final runtime = LinuxInteractivity.instance;
    return AnimatedBuilder(animation:runtime,builder:(_,__) {
      final activation = runtime.active;

      final item = activation?['item'] as Map? ?? {};
      final trigger = activation?['trigger'] as Map? ?? {};
      final contents = trigger['content'] as List? ?? [];
      final zones = contents.expand((e)=>(e['zones'] as List? ?? [])).toList();
      final width = (item['resolution_width'] as num? ?? 1920).clamp(1,8192).toDouble();
      final height = (item['resolution_height'] as num? ?? 1080).clamp(1,8192).toDouble();
      return Stack(fit:StackFit.expand,children:[
        Offstage(offstage:activation != null && !runtime.overlay,child:child),
        if (activation != null && !runtime.overlay) const ColoredBox(color:Colors.black),
        LayoutBuilder(builder:(context, box)=>Stack(children:[
          for (var index=0;index<zones.length;index++) Positioned(
            left:(zones[index]['x'] as num? ?? 0).toDouble()*box.maxWidth/width,
            top:(zones[index]['y'] as num? ?? 0).toDouble()*box.maxHeight/height,
            width:(zones[index]['width'] as num? ?? width).toDouble()*box.maxWidth/width,
            height:(zones[index]['height'] as num? ?? height).toDouble()*box.maxHeight/height,
            child:VideoPlaylistWidget(key:ValueKey('${item['id']}:$index:${identityHashCode(activation)}'),zoneId:'trigger-$index',
              mediaItems:(zones[index]['mediaItems'] as List? ?? []).map((e)=>MediaItem.fromJson(Map<String,dynamic>.from(e))).toList(),
              campaignId:'trigger:${item['id']}',campaignCanPlay:true,campaignSchedule:null,
              coordinateBaseWidth:width,coordinateBaseHeight:height),
          ),
          for (final rect in runtime.captureRegions(box.maxWidth,box.maxHeight)) Positioned(
            left:rect[0],top:rect[1],width:rect[2],height:rect[3],
            child:GestureDetector(behavior:HitTestBehavior.opaque,onTapDown:(_){},child:const SizedBox.expand()),
          ),
        ])),
      ]);
    });
  }
}
