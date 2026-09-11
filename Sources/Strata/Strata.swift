import Foundation
import SwiftUI
import AppKit

struct MindNode: Identifiable, Codable, Equatable { let id: UUID; var title: String; var children: [MindNode]; init(id: UUID = UUID(), title: String, children: [MindNode] = []) { self.id=id; self.title=title; self.children=children } }

@MainActor final class MindMapStore: ObservableObject {
 @Published var root = MindNode(title: "主题")
 @Published var selectedID: UUID?
 init(){ selectedID=root.id }
 func node(_ id: UUID?) -> MindNode? { guard let id else{return nil}; return find(id,root) }
 func addChild(){ guard let id=selectedID else{return}; update(id){$0.children.append(MindNode(title:"新节点"))}; selectedID=node(id)?.children.last?.id }
 func addSibling(){ guard let id=selectedID, id != root.id, let p=parent(id) else{return}; update(p){ n in if let i=n.children.firstIndex(where:{$0.id==id}){n.children.insert(MindNode(title:"新节点"),at:i+1)} }; selectedID=node(p)?.children.first(where:{$0.title=="新节点"})?.id }
 func delete(){ guard let id=selectedID,id != root.id,let p=parent(id) else{return}; update(p){$0.children.removeAll{$0.id==id}};selectedID=p }
 func rename(_ text:String){guard let id=selectedID else{return};update(id){$0.title=text}}
 func move(_ id:UUID,to parentID:UUID,index:Int?=nil){guard id != parentID, !isAncestor(id, of: parentID), let value=remove(id,&root),find(parentID,root) != nil else{return};update(parentID){p in let i=min(index ?? p.children.count,p.children.count);p.children.insert(value,at:i)};selectedID=id}
 func moveBefore(_ id: UUID, _ target: UUID) { moveRelative(id, target, after: false) }
 func moveAfter(_ id: UUID, _ target: UUID) { moveRelative(id, target, after: true) }
 private func moveRelative(_ id: UUID, _ target: UUID, after: Bool) { guard id != target, !isAncestor(id, of: target), let value = remove(id, &root), let p = parent(target) else { return }; update(p) { n in guard let i = n.children.firstIndex(where: {$0.id == target}) else { return }; n.children.insert(value, at: after ? i + 1 : i) }; selectedID = id }
 private func isAncestor(_ ancestor: UUID, of descendant: UUID) -> Bool { guard let n = find(ancestor, root) else { return false }; return find(descendant, n) != nil }
 func leaves()->String{leaf(root).joined(separator:"\n")}
 func save(_ url:URL)throws{try JSONEncoder().encode(root).write(to:url,options:.atomic)}
 func open(_ url:URL)throws{root=try JSONDecoder().decode(MindNode.self,from:Data(contentsOf:url));selectedID=root.id}
 private func find(_ id:UUID,_ n:MindNode)->MindNode?{if n.id==id{return n};for c in n.children{if let x=find(id,c){return x}};return nil}
 private func parent(_ id:UUID)->UUID?{func w(_ n:MindNode)->UUID?{if n.children.contains(where:{$0.id==id}){return n.id};for c in n.children{if let x=w(c){return x}};return nil};return w(root)}
 private func update(_ id:UUID,_ f:(inout MindNode)->Void){func w(_ n:inout MindNode){if n.id==id{f(&n);return};for i in n.children.indices{w(&n.children[i])}};w(&root)}
 private func remove(_ id:UUID,_ n:inout MindNode)->MindNode?{if let i=n.children.firstIndex(where:{$0.id==id}){return n.children.remove(at:i)};for i in n.children.indices{if let x=remove(id,&n.children[i]){return x}};return nil}
 private func leaf(_ n:MindNode)->[String]{n.children.isEmpty ? [n.title] : n.children.flatMap(leaf)}
}


struct ContentView:View{
 @ObservedObject var store:MindMapStore;@State private var editing:UUID?;@State private var draft="";@State private var showText=false
 var body:some View{VStack(spacing:0){HStack{Button("打开"){open()};Button("保存"){save()};Button("末级转纯文本"){showText=true};Spacer()}.padding(8);Divider();ScrollView([.horizontal,.vertical]){NodeView(node:store.root,store:store,editing:$editing,draft:$draft).padding(50)}}.onDeleteCommand{store.delete()}.sheet(isPresented:$showText){VStack{Text("末级节点").font(.headline);TextEditor(text:.constant(store.leaves())).frame(minWidth:500,minHeight:300);Button("关闭"){showText=false}}.padding()}}
 func save(){let p=NSSavePanel();p.allowedContentTypes=[.json];p.nameFieldStringValue="Strata.json";if p.runModal() == .OK,let u=p.url{try?store.save(u)}}
 func open(){let p=NSOpenPanel();p.allowedContentTypes=[.json];if p.runModal() == .OK,let u=p.url{try?store.open(u)}}
}

struct NodeView:View{
 let node:MindNode;@ObservedObject var store:MindMapStore;@Binding var editing:UUID?;@Binding var draft:String
 var body:some View{VStack(alignment:.leading,spacing:18){nodeLabel;if !node.children.isEmpty{HStack(alignment:.top,spacing:28){ForEach(node.children){c in NodeView(node:c,store:store,editing:$editing,draft:$draft).onDrag{NSItemProvider(object:c.id.uuidString as NSString)}.onDrop(of:[.text],delegate:NodeDropDelegate(target:c.id,store:store))}}}}}
 @ViewBuilder var nodeLabel:some View{if editing==node.id{TextField("节点",text:$draft,onCommit:{store.rename(draft);editing=nil}).textFieldStyle(.roundedBorder).frame(width:160).onAppear{draft=node.title}}else{Text(node.title).padding(10).background(node.id==store.selectedID ? Color.accentColor.opacity(0.3):Color.secondary.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius:8)).onTapGesture{store.selectedID=node.id}.onTapGesture(count:2){editing=node.id;draft=node.title}.onKeyPress(.return){store.addSibling();return .handled}.onKeyPress(.tab){store.addChild();return .handled}}}
}
struct NodeDropDelegate: DropDelegate {
 let target: UUID; let store: MindMapStore
 func dropEntered(info: DropInfo) { }
 func performDrop(info: DropInfo) -> Bool {
  guard let p = info.itemProviders(for: [.text]).first else { return false }
  let point = info.location
  p.loadObject(ofClass: NSString.self) { object, _ in
   guard let s = object as? String, let id = UUID(uuidString: s) else { return }
   Task { @MainActor in
    if point.y < 14 { store.moveBefore(id, target) }
    else if point.y > 34 { store.moveAfter(id, target) }
    else { store.move(id, to: target) }
   }
  }
  return true
 }
}
